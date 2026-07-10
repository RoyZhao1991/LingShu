import Foundation

/// 一条可续的派发任务线程(供上下文感知分诊识别"用户在回答哪条任务的提问")。
struct TriageThread {
    let label: String       // T1/T2…(给分诊器引用)
    let recordID: String    // 对应隔离子任务记录
    let summary: String     // 标题 + 它上次说的话(+是否⏳正等回答)
}

/// 分诊上下文:近上下文(逐字)+ 远上下文(压缩摘要)+ 可续任务线程。
struct TriageContext {
    let near: String
    let far: String
    let threads: [TriageThread]
}

/// 主线程输入归属解析:只回答"这条输入是在回复哪条等待中的上下文吗?"。
/// 它不判断 chat/task,也不创建子任务;新顶层目标一律交给当前主脑的 active turn 处理。
@MainActor
extension LingShuState {

    enum DispatchKind { case chat, task, reply }
    enum DispatchConfidence: Equatable { case high, medium, low }

    /// 输入归属决策:只允许 `.reply` 或 `.chat`。`.task` 仅保留给旧派发/队列兼容分支,入口解析不再产出。
    struct DispatchDecision {
        let kind: DispatchKind
        let goal: String?
        let replyRecordID: String?
        var confidence: DispatchConfidence = .high
        var actionHint: Bool = false     // 兼容旧字段:不再参与入口路由
        var brainFailed: Bool = false     // 归属解析失败/超时 → 不劫持输入,交主脑处理
    }

    /// 上下文归属解析:
    /// - 无候选线程:不调用模型,直接交主脑 active turn。
    /// - 有候选线程:只判断最新输入是否在回复/补充其中一条;不判断它是不是新任务。
    /// - 模型使用当前启用的主脑,不走强/中/弱脑分流。
    func classifyDispatch(_ prompt: String, hasAttachments: Bool = false, visiblePrompt: String? = nil) async -> DispatchDecision {
        let routingPrompt = (visiblePrompt ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if isMinimalVoiceMode {
            appendTrace(kind: .route, actor: "上下文归属", title: "极简语音 · 交主脑",
                        detail: "极简语音模式不做上下文劫持,交当前主脑处理。")
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil)
        }

        let ctx = buildTriageContext()
        let candidateThreads = ctx.threads
        guard !candidateThreads.isEmpty else {
            appendTrace(kind: .route, actor: "上下文归属", title: "无待归属线程",
                        detail: "未发现等待用户回答/可续的线程;不做模型分诊,直接交当前主脑判断并响应。")
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil)
        }

        var threadBlock = ""
        let lines = candidateThreads.map { "[\($0.label)] \($0.summary)" }.joined(separator: "\n")
        threadBlock = "\n【候选待归属线程】\n\(lines)\n"
        let far = ctx.far.isEmpty ? "" : "【更早对话摘要(压缩)】\n\(ctx.far)\n\n"
        let system = """
        你是"上下文归属解析器",只做一件事:判断用户【最新一条】是否是在回复/补充/确认下面某条候选线程。
        不要判断这条消息是不是新任务,不要规划,不要创建子任务,不要按关键词猜测。
        只输出一行 JSON:
        - 归属明确: {"route":"reply","thread":"T1","confidence":"high"}
        - 不归属/不确定: {"route":"none","confidence":"high"}

        判定规则:
        - 只有当最新输入明显是在回答候选线程的问题、补充候选线程所需信息、确认候选线程给出的选项,才 route=reply。
        - "继续"这类无主体短句,只在最近一条待处理上下文就是候选线程且语义明确时归属;否则 route=none,交主脑处理最近聊天上下文。
        - 如果用户在开启一个新话题、问一个新问题、提出一个新目标,即使文字里有"继续/PPT/演示/文件/代码"等词,也必须 route=none。
        - 多个候选都可能匹配时 route=none,不要替用户猜。

        \(far)【近期对话(逐字)】
        \(ctx.near)
        \(threadBlock)
        """
        let latestInput = """
        用户可见输入:
        \(routingPrompt)

        模型扩展输入:
        \(prompt)
        """
        let payloadChars = system.count + latestInput.count + 8
        let classifier = LingShuAgentSession(
            id: "context-resolver-\(UUID().uuidString.prefix(6))",
            system: system, tools: [], model: makeAgentModelAdapter(maxAttempts: 1), maxTurns: 1
        )
        let callStart = Date()
        let result = await classifier.send(latestInput)
        let elapsedMs = Int(Date().timeIntervalSince(callStart) * 1000)
        let callDetail = "role=上下文归属, provider=\(modelProvider), model=\(modelName), elapsed=\(elapsedMs)ms, payloadChars=\(payloadChars), brain=当前主脑"
        appendTrace(kind: .model, actor: "上下文归属", title: "当前主脑归属判断 · \(modelName)", detail: callDetail)
        LingShuControlPlaneBaseline.baselineLog("输入=「\(prompt.prefix(50))」\n  ├ \(callDetail)")
        guard case .completed(let raw) = result else {
            appendTrace(kind: .warning, actor: "上下文归属", title: "归属判断未完成",
                        detail: "当前主脑未返回归属结果,耗时\(elapsedMs)ms;为避免卡死/误劫持,交主脑按普通输入继续处理。")
            LingShuControlPlaneBaseline.baselineLog("  └ 归属判断失败,耗时\(elapsedMs)ms → route=none")
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil, confidence: .medium, brainFailed: true)
        }
        let text = LingShuReasoningText.stripThinkTags(raw)
        let decision = Self.parseContextResolverDecision(text, threads: candidateThreads)
        // **第③站基线观测·抓手2(structured output 脏率)**:模型是否直接吐纯 JSON,还是靠 stripThinkTags/清洗才解析出结构。
        let jsonDirty = LingShuControlPlaneBaseline.isDirtyJSON(raw: raw, cleaned: text)
        let outputDetail = LingShuControlPlaneBaseline.outputDetail(raw: raw, cleaned: text, jsonDirty: jsonDirty, brainConfidence: "\(decision.confidence)")
        appendTrace(kind: jsonDirty ? .warning : .model, actor: "上下文归属",
                    title: "归属输出 · JSON\(jsonDirty ? "脏" : "净")", detail: outputDetail)
        LingShuControlPlaneBaseline.baselineLog("  └ \(outputDetail)")
        return decision
    }

    /// 归属解析只做候选线程匹配,失败时不追问、不劫持;交主脑根据完整对话自然处理。
    func kernelGateClarifyDirective(_ d: DispatchDecision) -> String? {
        _ = d
        return nil
    }

    /// 内核闸门的处置结果(图里 D 扇出的方向)。
    enum GateOutcome: Equatable {
        case execute              // 高置信 + 合规 → 照常按 kind 扇出执行
        case clarify(String)      // 低置信 / 脑失败 → 追问指令(先与用户确认意图,别猜)
    }

    /// **内核校验闸门(图里 D)**:吃〈分诊决策 + 结构化结果〉,统一决定走执行还是追问——
    /// 决策重心从 triage.kind 收拢到这里(kind 退化为 execute 分支内部的扇出依据)。
    /// 低置信/脑失败 → clarify(对 **chat 和 task 一视同仁**,不再只拦 chat);其余 → execute。
    /// reply 走自身的活跃线程兜底,不在此追问。注:危险/不可逆的权限确认(图里 G)当前仍在工具执行时拦,
    /// 后续把危险评估上提到此闸门(goalSpec 预留给那一步用)。
    func kernelGate(_ d: DispatchDecision, goalSpec: LingShuGoalSpec?) -> GateOutcome {
        if d.kind == .reply { return .execute }
        if let directive = kernelGateClarifyDirective(d) { return .clarify(directive) }
        // **步骤4·结构化结果回流改路由**:triage 判 task,但派生的 GoalSpec 反而拆成「可直接回答的问答」(非交付型),
        // 且 triage 置信不到 high → 这是 triage 与结构化的冲突。别盲目开跑后台任务,转追问让用户定夺。
        // 只在「冲突 + 非高置信」时触发(不误伤 actionHint 双印证的高置信真任务);这是把结构化喂回决策的**安全切口**——
        // 只会多一次追问,绝不静默改判。根治了原来「kind 在 triage 锁死、结构化只当执行资料」的拓扑反转。
        if d.kind == .task, d.confidence != .high, goalSpec?.kind == .question {
            return .clarify("(系统提示:这条像是要执行的任务,但拆解下来更像一个可以直接回答的问题。先跟用户确认一句:是要你**动手做出交付物**,还是**直接回答**就行?确认后再决定。)")
        }
        return .execute
    }

    /// 构造分诊上下文:近上下文(最近逐字,派发线程消息打 [Tk] 标签)+ 远上下文(对话摘要压缩)+ 可续派发线程清单。
    func buildTriageContext() -> TriageContext {
        let dispatchedRecordIDs = Set(agentSubTaskRecords.values)
        // 可续线程 = 近 40 条聊天里出现过的、属于隔离子任务的灵枢消息,取每条线程最近一句作为"它上次说的"。
        var lastSay: [String: (text: String, at: Date)] = [:]
        for m in chatMessages.suffix(40) where !m.isUser {
            guard let rid = m.taskRecordID, dispatchedRecordIDs.contains(rid) else { continue }
            lastSay[rid] = (m.text, m.createdAt)
        }
        let ordered = lastSay.sorted { $0.value.at > $1.value.at }.prefix(3)   // 取最近 3 条线程
        var threads: [TriageThread] = []
        // **主会话刚问了问题在等回答** → 作为首条可续线程加进分诊上下文(标⏳),让分诊器能把「答复」路由回它、
        // 也能把「新任务」照常判成 task 去派子线程(不再无脑把后续都塞回主会话→阻塞)。它不是派发线程,路由时单独识别。
        if let pendingQ = pendingMainQuestionRecordID,
           let rec = taskExecutionRecords.first(where: { $0.id == pendingQ }) {
            let lastAsk = rec.messages.last(where: { $0.actor == "灵枢" })?.text ?? rec.summary
            threads.append(.init(label: "T1", recordID: pendingQ,
                                 summary: "⏳正等你回答 标题=「\(rec.title.prefix(28))」 它上次问:「\(lastAsk.prefix(120))」"))
        }
        for kv in ordered {
            let title = taskExecutionRecords.first(where: { $0.id == kv.key })?.title ?? "任务"
            let awaiting = kv.key == blockedDispatchedRecordID ? "⏳正等你回答 " : ""
            let summary = "\(awaiting)标题=「\(title.prefix(28))」 它上次说:「\(kv.value.text.prefix(120))」"
            threads.append(.init(label: "T\(threads.count + 1)", recordID: kv.key, summary: summary))
        }
        // 近上下文:最近 8 条逐字,线程消息打标签(让分诊器看清这句话属于哪条线程)。
        let labelByRecord = Dictionary(threads.map { ($0.recordID, $0.label) }, uniquingKeysWith: { a, _ in a })
        var near: [String] = []
        for m in chatMessages.suffix(8) {
            let who = m.isUser ? "用户" : (m.taskRecordID.flatMap { labelByRecord[$0] }.map { "灵枢[\($0)]" } ?? "灵枢")
            near.append("\(who): \(m.text.prefix(140))")
        }
        let far = persistedConversationDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(near: near.joined(separator: "\n"), far: String(far.prefix(500)), threads: threads)
    }

    /// 把一个任务派发给**独立隔离 session** 并行跑(Stage 2 真隔离):本任务自己的 record + 全新 session,
    /// 经 `orchestrator.spawnDetached` 后台并发(maxConcurrent 3),**不挂主 session、不串上下文**。
    /// 返回即时确认(加载气泡);完成/卡住/失败由编排器事件回填该气泡(见 handleOrchestratorEvent)。
    /// 移除一个**还在 loading 的占位气泡**(分诊判为入队/续接到已有线程时,submitTextInput 预放的答复占位不再用)。
    /// 只移除 loading 态,避免误删已有正文的真气泡。
    func removeChatBubble(_ id: UUID) {
        chatMessages.removeAll { $0.id == id && $0.isLoading }
    }

    @discardableResult
    func dispatchIsolatedTask(prompt: String, taskRecordID: String, goal: String?, existingBubbleID: UUID? = nil,
                              makerAgentID: String? = nil, makerName: String? = nil,
                              checkerAgentID: String? = nil, checkerName: String? = nil,
                              extraCheckerAgentIDs: [String] = [], imageDataURLs: [String]? = nil) -> String {
        installAgentEventSinkIfNeeded()
        // **附件直接入脑·覆盖派发任务**(2026-06-28 修):复杂任务都走这条隔离路,以前只把附件 VL→文字塞进 objective、
        // 原图没进多模态脑(实测:改 PPT 任务只拿到"图片内容摘要"、看不见红框、改错了箭头)。这里把原图随首轮目标直发大脑。
        // 即时派发从 pending 消费;排队后派发由调用方把当时暂存的图传进来(pending 那会儿已被清/被后续覆盖)。
        let directImages = imageDataURLs ?? consumePendingDirectBrainImages()
        interruptSpeechOutput?()
        let subID = "task-\(UUID().uuidString.prefix(6))"
        agentSubTaskRecords[subID] = taskRecordID   // 预映射:.spawned 据此复用这条记录,不另建
        if let goal, !goal.isEmpty, let i = taskExecutionRecords.firstIndex(where: { $0.id == taskRecordID }) {
            taskExecutionRecords[i].goal = goal
            persistTaskExecutionRecords()
        }
        // **顺序修(2026-06-23)**:复用 submitTextInput 已同步放在用户消息后的占位气泡(保持 Q→A 交错),没给才新建。
        let intake = dialogueAcknowledgement.intake(for: prompt)
        let bubbleID: UUID
        if let existingBubbleID, let idx = chatMessages.firstIndex(where: { $0.id == existingBubbleID }) {
            chatMessages[idx].text = intake
            chatMessages[idx].taskRecordID = taskRecordID
            chatMessages[idx].isLoading = true
            bubbleID = existingBubbleID
        } else {
            let pending = ChatMessage(speaker: "灵枢", text: intake, isUser: false, isLoading: true, taskRecordID: taskRecordID)
            chatMessages.append(pending)
            bubbleID = pending.id
        }
        dispatchedTaskBubbles[taskRecordID] = bubbleID
        appendTrace(kind: .route, actor: "主线程分诊", title: "派发隔离任务", detail: "判为执行任务,派生独立隔离 session 并行推进(不进主对话上下文)。")

        // 引擎接缝:解析 maker + checker 评审绑定(谁开发 / 谁验收 / 是否异源),存下供验收复用,并**明确标注**。
        // 灵枢始终用本地脑当编排/验收 session 的模型;**maker 是外部 agent 时**(@Codex 等),开发由灵枢在 LOOP 里
        // 经 run_agent 委托给该 agent(它才是真 maker),灵枢/另一个 agent 当 checker——maker≠checker 跨厂商验收。
        let adapter = routedModelAdapter(taskRecordID: taskRecordID)
        let binding: LingShuReviewBinding
        if let makerAgentID, let makerName {
            let makerEngine = LingShuAgentEngineDescriptor(id: "external:\(makerAgentID)", kind: .externalCLI, providerLabel: makerName, available: true)
            let checkerEngine: LingShuAgentEngineDescriptor
            if let checkerAgentID, let checkerName {
                checkerEngine = .init(id: "external:\(checkerAgentID)", kind: .externalCLI, providerLabel: checkerName, available: true)
            } else {
                checkerEngine = .init(id: "localBrain:\(modelProvider.lowercased())", kind: .localBrain, providerLabel: modelProvider, available: true)
            }
            binding = .init(maker: makerEngine, checker: checkerEngine, crossSource: true)
        } else if let checkerAgentID, let checkerName {
            // **灵枢自己当 maker + 指定外部 agent 当 checker**(如「灵枢开发 + @Codex 验收」):maker=本地脑、checker=外部 agent。
            let makerEngine = LingShuAgentEngineDescriptor(id: "localBrain:\(modelProvider.lowercased())", kind: .localBrain, providerLabel: modelProvider, available: true)
            let checkerEngine = LingShuAgentEngineDescriptor(id: "external:\(checkerAgentID)", kind: .externalCLI, providerLabel: checkerName, available: true)
            binding = .init(maker: makerEngine, checker: checkerEngine, crossSource: true)
        } else {
            binding = reviewBinding(forMaker: resolveMakerEngine(taskRecordID: taskRecordID).engine)
        }
        taskReviewBindings[taskRecordID] = binding
        if !extraCheckerAgentIDs.isEmpty { taskExtraCheckerAgentIDs[taskRecordID] = extraCheckerAgentIDs }   // 多 checker
        appendTrace(kind: .system, actor: "派发引擎", title: "maker / checker 绑定", detail: binding.label + (extraCheckerAgentIDs.isEmpty ? "" : " +\(extraCheckerAgentIDs.count) checker"))
        // **统一给 maker 打标(灵枢当 maker 时也明确标 maker 角色,不再只显示「派生子任务/分析」让人看不出谁是 maker)**:
        // agent 当 maker 由 run_agent 落「开发(maker)」标;灵枢当 maker 在这里补一条,让 LOOP 两角色从启动都可见。
        if makerAgentID == nil {
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "开发(maker)·上岗", kind: .agent,
                                    text: "▶ 灵枢(maker)接手开发本任务;完成后由独立 checker 验收。")
        }
        // 边做边想:派发的隔离子任务也要把模型每步动作前的旁白落进**这条任务自己的记录**——否则任务窗口
        // 只见工具调用、缺"运行时思考",看不出每步为什么这么做。记录 id 用本子任务的(主会话用 currentAgentTurnRecordID,
        // 这里不同);后台并行跑,不抢全局 missionStatus。
        adapter.onReasoning = { [weak self] aside in
            Task { @MainActor in self?.recordAgentReasoning(aside, recordID: self?.agentSubTaskRecords[subID], updateMissionStatus: false) }
        }
        let recordProvider: @MainActor @Sendable () -> String? = { [weak self] in self?.agentSubTaskRecords[subID] }
        let dispatchedWorkingDir = effectiveAgentWorkingDirectory(override: Self.explicitWorkingDirectoryHint(in: prompt))
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: dispatchedWorkingDir), withIntermediateDirectories: true)
        agentSubTaskWorkingDirectories[subID] = dispatchedWorkingDir
        let tools = withPhaseTracking(   // 相位跟踪:派发任务也驱动本体显示理解/规划/执行/验收(光球随环节变色变脉动)
            // 继承父上下文的 shell 预授权:在岗/自主完整授权时给 autoAllowShell,否则派发任务跑 shell 会卡在审批框(见 dispatchedTaskExecutionPolicy)。
            agentBuiltinTools(recordIDProvider: recordProvider, executionPolicy: dispatchedTaskExecutionPolicy, workingDirectoryOverride: dispatchedWorkingDir)
            + [Self.timeTool(), Self.locationTool(), webSearchTool(), recallMemoryTool(), Self.askUserTool(),
               findImagesTool(), acquireResourceTool(),
               updateTaskPlanTool(recordIDProvider: recordProvider), reviewDesignTool(recordIDProvider: recordProvider), speakTool(), digitalHumanTool(), enterManagedModeTool()]
            + agentPluginTools(recordIDProvider: recordProvider, includeRegistration: false)
            + previewTools()
            + browserTools()           // 内置浏览器(网页演示/自动化)
            + backgroundWatchTools()   // 派发的长任务正是"等外部条件(构建/部署/下载)再续"的主场,必须有 watch_until
            + scheduledTaskTools()     // 派发任务也能挂定时(如"建好后明天提醒我部署"),接真调度系统,不再伪造 launchd/crontab
        )
        // 注入"最近产出物"上下文:让"运行起来/继续/改一下"这类派发任务接得上(知道刚做了什么、在哪、怎么跑),
        // 不再重新扫工作目录瞎猜(根治"超级玛丽做完了却问我要运行哪个项目")。
        // + 当前项目结构(文件树):多轮迭代同一项目时,免每轮从头探索代码(用户实测"没上次记忆")。
        let combinedCtx = [currentProjectStructureContext(), recentDeliverablesContext()]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        // **前置认知引导也注入派发任务**(P1 目标 / P2 缺口补齐 / P4 历史经验)——派发不走 driveAgentDelivery,
        // 此前这些引导只到主会话/自主、漏了派发任务(P4 live 实测暴露)。经 system initialMessage 补上。
        var initialMessages: [LingShuAgentMessage] = combinedCtx.isEmpty ? [] : [.init(role: .system, content: combinedCtx)]
        let preflightGuidance = assembledExecutionGuidance(base: nil, taskRecordID: taskRecordID)
        if !preflightGuidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initialMessages.append(.init(role: .system, content: preflightGuidance))
        }
        let agentGrounding = [agentPluginGroundingText(), agentCapabilitiesGroundingText()]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        if !agentGrounding.isEmpty { initialMessages.append(.init(role: .system, content: agentGrounding)) }
        // **通用 skill 可发现性也注入派发任务**(2026-06-27 修覆盖盲区):`matchedSkillHint` 此前只在主会话(executeMainTurn)
        // 注入、漏了派发任务——而复杂任务一律走派发,于是永远看不到匹配的固化技能、从零现编(端到端实测实锤:做PPT派发
        // 38次run_command没碰ppt-builder)。这是**通用机制**(按 skill 自己声明的 triggers 匹配,不写死任何场景),
        // 该和主会话一个待遇。注入后用不用、用哪个仍是大脑判断——系统只负责"呈现",不替它"选用"。
        if let skillHint = matchedSkillHint(for: prompt) {
            initialMessages.append(.init(role: .system, content: skillHint))
        }
        // **产物邻里勘探(通用,2026-06-28)**:任务引用了绝对路径文件 → 把这些文件**所在目录**的清单 + "改源而非改成品"铁律注入,
        // 让 agent 看见旁边的源 / 模板 / 生成器(根治实测:改 PPT 图时只点验 PNG、从没整列目录、没认出 `.gen.py` 源 → 退化成像素手术)。
        let neighborhood = Self.artifactNeighborhoodContext(for: prompt)
        if !neighborhood.isEmpty { initialMessages.append(.init(role: .system, content: neighborhood)) }
        // **能看就别写像素码**(仅多模态脑):有眼睛就直接看图识别标记/核验结果,别写逐像素扫描比对
        // (实测把"删一行字"拖成 20+ 分钟还判错——把方框描边当文字)。非多模态脑没眼睛,不注入。
        if shouldAttemptNativeMultimodalForCurrentModel() {
            initialMessages.append(.init(role: .system, content: Self.visionOverPixelsDirective))
        }
        // **maker 是外部 agent(@Codex 等):把开发委托给它,你只编排+验收(maker≠checker 跨厂商)。**
        // 这条让 LOOP 以 codex 当 maker 跑——之前 maker 是灵枢自己的 session,现在换成 codex session,LOOP/验收/目标解析全不变。
        if let makerAgentID, let makerName {
            let checkerWho = checkerName ?? "异源审查员(独立会话,不同于你)"
            initialMessages.append(.init(role: .system, content: """
            【本任务的 maker / checker(用户定调:任何任务都走 LOOP;maker 与 checker 是**两条独立会话**,绝不自评)】
            开发(maker)= **\(makerName)** agent。验收(checker)= **\(checkerWho)**(由**系统在你交付后自动**调起的独立会话)。你(灵枢)是**编排者**。
            你**只**做三件事,做完就停:
            1. **理解 + 规划**:把目标、成功标准想清楚(已有 GoalSpec 就对齐它)。
            2. **委托 maker 开发**:调 `run_agent(agent:"\(makerAgentID)", objective:"<完整开发目标 + 成功标准 + 要落地的文件/可运行>")`,让 \(makerName) 真写代码、落文件、跑起来。
            3. **如实汇报 maker 产出**(做了什么、落了哪些文件),然后**结束你的回合**。
            **铁律(maker≠checker 靠这条落地)**:验收**不归你管**——系统会在你结束后自动让独立 checker(\(checkerWho))复核。
            所以你**绝不**自己写代码、**绝不**调 `run_agent` 去做"复核/验收"、**绝不**自己跑测试来下"验收通过/不通过"的结论、**绝不**替 checker 拍板。
            (你顺手 cat/读一眼确认 maker 真落了盘可以,但**判过没过是 checker 的事,不是你的事**。)若你确知 maker 明显没落地/报错,可让它先返工再交回;但绝不假装完成。
            """))
        } else {
            // **默认(灵枢自己当 maker):明确 maker 角色 + 会有独立 checker 会话(LOOP 两角色,从启动赋予不同任务)。**
            initialMessages.append(.init(role: .system, content: """
            【本任务你是开发方(maker)· LOOP 两个独立角色】
            你负责**开发 / 产出**。你完成后,会有一个**独立的验收官(checker)**(另一条会话/agent、独立上下文,看不到你的内部过程)**独立核验**你的产出——它会真去 read_file 看代码、run_command 跑测试 / 把程序运行起来。
            所以:① 真正做完做对,产物**真实落盘**;② 写了代码就**自己先跑一遍测试 / 运行起来**确认能用;③ 别只口头声称完成——checker 会独立核,过不了会打回让你修。
            ④ **铁律:你只管开发,别自行找别的 agent 代替系统 checker 自评**——独立 checker 由系统在你交付后**自动**跑,不归你管;你交付后就结束回合。**但如果当前或后续用户明确指定某外部 agent 参与/复核/验收(如 Codex),必须按用户要求调用 `run_agent` 委托,不要说没有能力。**
            """))
        }
        let sub = makeAgentSession(
            id: subID,
            system: Self.dispatchedTaskSystemPrompt(workingDir: dispatchedWorkingDir),
            initialMessages: initialMessages,
            tools: tools,
            model: adapter,
            // 安全天花板(防失控),非目标预算——复杂工程的「读→改→构建→测试→修」单段推进
            // 真能远超 40 步(超级玛丽暴露:40 太低,撞顶就被当失败/异常收尾)。抬到 120 让它纯做防失控用;
            // 真停止位仍是目标达成/停滞(5 次重复)/撞顶后由 verifyAndContinue 续跑恢复(见编排器委托)。
            maxTurns: 120,
            recordIDProvider: recordProvider   // .nested 阶段验收据此定位本派发任务记录
        )
        let orchestrator = agentOrchestrator
        Task { @MainActor [weak self] in
            await self?.prepareSubtaskArtifactDelta(subID: subID, recordID: taskRecordID, workingDirectory: dispatchedWorkingDir)
            if await orchestrator.spawnDetached(id: subID, objective: prompt, session: sub, imageDataURLs: directImages) { return }   // 有空位,直接派出(带真图)
            // 满并发上限(N=3)→ **不直接拒绝用户任务,改排队**:轮询等空位再自动派出(bubble 保持加载=排队中)。
            // 老练度补齐(2026-06-19):用户快速连发几条任务时旧逻辑直接拒"重发一次"体验差;改为自动排队续派。
            // (注:模型自己 spawn_task 的路径仍保持硬背压不变——那是防模型一次甩几十个子任务 runaway,与用户连发不同。)
            for _ in 0..<300 {   // 最长约 10 分钟(每 2s 查一次空位)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.agentSubTaskRecords[subID] != nil else { return }   // 已被取消/清掉 → 停止排队
                if await orchestrator.spawnDetached(id: subID, objective: prompt, session: sub, imageDataURLs: directImages) { return }   // 轮到了,编排器事件接管 bubble
            }
            guard let self else { return }
            self.fillDispatchedBubble(taskRecordID, text: "前面任务排队较久仍没轮到,先没派出去——稍后重发即可。")
            self.agentSubTaskRecords[subID] = nil
        }
        return intake
    }

    /// 用户这条是在**回答/延续某条派发的隔离任务**(如它问"做什么主题"、或几条之前问过):续跑**那条隔离会话本身**
    /// (带真上下文),而不是另起新会话。这样"做PPT→问主题→你答主题"能接上去真把 PPT 做出来,不再答非所问。通用,不限 PPT。
    func continueDispatchedThread(prompt: String, recordID: String) {
        if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }   // 已回答,解除"正等回答"标记
        appendTrace(kind: .route, actor: "主线程分诊", title: "续答派发任务", detail: "判为对该派发任务的回复,续跑那条隔离会话(带真上下文,不另起)。")
        appendTrace(
            kind: .system,
            actor: "第⑤站",
            title: "上下文装配计划",
            detail: LingShuContextAssemblyPlan.continueExistingTask(
                recordID: recordID,
                source: "structured_route_reply",
                reason: "resume_dispatched_thread"
            ).traceLine
        )
        let pending = ChatMessage(speaker: "灵枢", text: dialogueAcknowledgement.intake(for: prompt), isUser: false, isLoading: true, taskRecordID: recordID)
        chatMessages.append(pending)
        dispatchedTaskBubbles[recordID] = pending.id   // 完成由编排器事件回填这条气泡
        submitTaskFollowup(prompt, recordID: recordID) // 隔离子任务 → orchestrator.resumeWithInput(续那条会话)
    }

    /// 回填某条派发任务的加载气泡(完成/失败/背压时用);找不到就追加一条。回填后清掉映射。
    func fillDispatchedBubble(_ recordID: String, text: String) {
        let displayText = LingShuVisibleModelText.clean(text)
        let shouldAwaitUser = dispatchedRecordNeedsUserInput(recordID)
        // **修(2026-06-27):只有任务真在等用户输入(blocked/waiting)时才解析/渲染选项卡。**
        // 否则**已完成**的交付文本里的编号清单(如"三页内容概览:1.封面 2... 3...")会被 LingShuChoiceParsing
        // 误抽成"无效选项卡"(用户实测:点了无效)——交付不是选择题,绝不该有选项。
        let choices = shouldAwaitUser
            ? (LingShuChoiceParsing.parse(displayText) ?? userPrerequisiteChoicePromptIfNeeded(resultText: displayText, taskRecordID: recordID))
            : nil
        let awaitingRecordID = shouldAwaitUser ? recordID : nil
        if let bubbleID = dispatchedTaskBubbles[recordID],
           let idx = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[idx].text = displayText
            chatMessages[idx].isLoading = false
            chatMessages[idx].choices = choices
            chatMessages[idx].awaitingInputForRecordID = awaitingRecordID
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: displayText, isUser: false, taskRecordID: recordID,
                                      choices: choices, awaitingInputForRecordID: awaitingRecordID))
        }
        dispatchedTaskBubbles[recordID] = nil
    }

    /// 派发任务是否正处在需要用户补前提/作选择的可续状态。
    /// 这只读任务记录的 typed 状态,不看具体平台名;目的是让任何授权/凭据/设备/付费边界
    /// 都回填成同一套 human-in-the-loop 气泡,避免普通文字把队列卡死。
    func dispatchedRecordNeedsUserInput(_ recordID: String) -> Bool {
        guard let record = taskExecutionRecords.first(where: { $0.id == recordID }) else { return false }
        if record.taskOutcome == .waitingForUser || record.taskOutcome == .partial { return true }
        return [.waitingForUser, .partial, .blocked].contains(record.status)
    }

    /// **任务卡住等用户输入 → 把它的气泡标成「待你输入」**(渲染气泡内回复控件:选项/追加信息)。
    /// 这样无论后面堆了多少聊天,回复都从这条气泡发出、**直达该任务隔离会话**(不靠分诊在历史里找回它)。
    func markDispatchedBubbleAwaitingInput(recordID: String, question: String) {
        let cleanQuestion = LingShuHumanInputEnvelope.userFacingText(from: question)
        let text = "⏸ 等待前提:\(cleanQuestion)"
        let choices = LingShuChoiceParsing.parse(question)
            ?? LingShuChoiceParsing.parse(cleanQuestion)
            ?? userPrerequisiteChoicePromptIfNeeded(resultText: cleanQuestion, taskRecordID: recordID)
        if let bid = dispatchedTaskBubbles[recordID], let idx = chatMessages.firstIndex(where: { $0.id == bid }) {
            chatMessages[idx].text = text
            chatMessages[idx].isLoading = false
            chatMessages[idx].choices = choices
            chatMessages[idx].awaitingInputForRecordID = recordID
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false, taskRecordID: recordID,
                                      choices: choices, awaitingInputForRecordID: recordID))
        }
        dispatchedTaskBubbles[recordID] = nil   // 这条气泡定稿成"待你输入";答复时新建续跑气泡
    }

    /// **气泡内直接回答一条等待输入的派发任务**(选项点击 / 追加信息提交):**直达那条隔离会话续跑**——
    /// 不经主输入框/分诊(避免被后续聊天淹没找不回),也**不受问答线活跃阻塞**(双线独立,故不查 hasActiveModelCall)。
    func answerDispatchedTask(recordID: String, answer: String, displayAnswer: String? = nil) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let visibleAnswer = (displayAnswer ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = chatMessages.firstIndex(where: { $0.awaitingInputForRecordID == recordID }) {
            chatMessages[i].awaitingInputForRecordID = nil           // 置灰这条"待输入"气泡
            if chatMessages[i].resolvedChoice == nil { chatMessages[i].resolvedChoice = visibleAnswer }
        }
        chatMessages.append(.init(speaker: "你", text: visibleAnswer, isUser: true, taskRecordID: recordID))   // 答复显示在气泡处,接上 Q→A
        requestChatScrollToLatestForUserSend()
        appendTaskRecordMessage(recordID, actor: "你", role: "答复", kind: .user, text: visibleAnswer)
        if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }
        guard let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key else {
            _ = runMainAgentTurn(prompt: trimmed, taskRecordID: recordID, resumeBlocked: true)   // 兜底:非隔离→主会话续
            return
        }
        installAgentEventSinkIfNeeded()
        let wasWaiting = taskExecutionRecords.first { $0.id == recordID }?.taskOutcome == .waitingForUser
        let providesPrerequisite = Self.userInputProvidesPrerequisite(trimmed)
        if wasWaiting && providesPrerequisite { resolveUserProvidedGaps(recordID: recordID) }
        let resumeInput = wasWaiting && providesPrerequisite
            ? trimmed + "\n\n" + capabilityResumePreamble(recordID: recordID)
            : trimmed
        let pending = ChatMessage(speaker: "灵枢", text: dialogueAcknowledgement.intake(for: visibleAnswer), isUser: false, isLoading: true, taskRecordID: recordID)
        chatMessages.append(pending)
        dispatchedTaskBubbles[recordID] = pending.id
        appendTrace(kind: .route, actor: "任务气泡", title: "气泡内直答", detail: "气泡内回复直达派发任务隔离会话(不经分诊)。")
        let orchestrator = agentOrchestrator
        Task { @MainActor [weak self] in
            await self?.prepareSubtaskArtifactDelta(subID: subID, recordID: recordID)
            await orchestrator.resumeWithInput(id: subID, input: resumeInput)
        }
    }

    /// 派发任务执行者的系统提示(隔离 session 用):LOOP 计划 + 真落盘 + 不造假的核心规则。
    nonisolated static func dispatchedTaskSystemPrompt(workingDir: String) -> String {
        """
        你是灵枢的任务执行者,独立隔离推进这一个任务直到达成。工作目录:\(workingDir)。
        - **先计划后执行**:第一个动作调 `update_plan` 给出 ① goal=一句话总目标(高度概括,不复述需求)② 3–7 步抽象计划(里程碑,不绑死实现路径);之后每步标 in_progress/completed。
        - **有产出物必须真落盘**:用 write_file/run_command 把文件真写进工作目录并给绝对路径,**绝不只口头说"已完成"**;跑命令前先确认依赖/文件存在,命令失败要自查重试,别拿报错当交付。
        - 写代码配测试并 run_command 跑通(全绿)再交付;改已有文件用 edit_file,新建/整体重写才用 write_file。
        - **代码任务=构建通过 + 程序真正运行不崩 + 测试全绿,三者缺一不可**:跑崩了/编译错/报错/抛异常都是**要修复的观测**,不是交付——别拿异常收尾甩给用户,一路修到真跑通。推进用满一段也别停,接着干到目标达成。
        - 需要实时/不确定的事实调 web_search;信息确实不足才 ask_user。
        - **别为小事反问(铁律,否则用户觉得"还不如自己干")**:用户**已明确指定的**(文件名/路径/格式/参数/数量等)**直接照用,绝不反问确认**——用户说了存到 `/x/y.txt` 就存那、绝不另编一个名再问用户;**约定性细节**(如斐波那契是否含0、缩进风格、是否打印日志)**按通行默认自行决定**,别为这种小事卡住问用户。只有真的缺了无法继续的关键信息(如必须的账号凭据)才 ask_user。验收里若出现与用户原话不符的占位文件名,**以用户原话为准**,别去满足那个占位名。
        - **定时/提醒/"每天X点"/"过一会儿提醒我"这类时间点触发,用 `schedule_task`(原生定时四肢,真持久化、到点把指令交回完整的我处理)——绝不写 launchd plist / crontab / shell 脚本假装设了定时(那是只写文件没接到系统的假象)。等"外部条件满足"才继续则用 `watch_until`。`list_scheduled_tasks`/`cancel_scheduled_task` 管理。
        - **要当面占屏实时演示 / 与主人实时互动答疑 / 接管屏幕操作时**:别自己直接 present_fullscreen 占屏——**先调 `enter_managed_mode`**(写清要实时做什么 + 文件绝对路径),它会弹窗征主人同意;同意后由托管会话接手实时演示/互动,你这条到此交接。普通做事(生成 PPT/写文件/查资料)不必调它。
        - 完成后用一句话给结果 + 关键产出物绝对路径。不暴露内部工具名/机制词。
        """
    }
}
