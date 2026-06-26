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

/// 主线程分诊(Stage 2 多任务真隔离的第一步):灵枢收到消息后**先判**能否直接对话作答(chat),
/// 还是需要派发执行(task)。chat 留主线程(连续对话);task 派发独立隔离 session 并行跑。
/// 旧的「启发式前置门」在 82fc503 被删,这里在现代 agent loop 之上重建一个轻量分诊。
@MainActor
extension LingShuState {

    enum DispatchKind { case chat, task, reply }
    enum DispatchConfidence: Equatable { case high, medium, low }

    /// 分诊决策(图里 B→C 的结构化产出):kind + 目标 + reply 目标 + **置信度** + 关键词信号 + 脑是否失败。
    /// 置信度是**融合**产物(大脑自报 × 关键词印证 × 一致性),供内核闸门据此扇出执行/追问——不全信模型自评。
    struct DispatchDecision {
        let kind: DispatchKind
        let goal: String?
        let replyRecordID: String?
        var confidence: DispatchConfidence = .high
        var actionHint: Bool = false     // 关键词门信号:降级后只当置信度外部锚,不再绕过大脑
        var brainFailed: Bool = false     // 分诊脑调用失败/超时 → 闸门显式追问,不静默吞成闲聊
    }

    /// **上下文感知**的轻量分诊(用户定调 2026-06-17):每次分诊都带上**完整语义的近上下文(最近逐字)+ 压缩的远上下文
    /// (对话摘要)+ 当前可续的派发任务线程**,让分诊器能(a)分得更准、(b)**回溯到前面隔了几条才问的问题**。
    /// 返回 reply 时附 `replyRecordID`。**架构升级(2026-06-26)**:关键词门从「return .task 抄近路」降级为 `actionHint`
    /// 信号(喂大脑当先验 + 融合进置信度);产出带 Confidence 的结构化决策;脑失败不静默吞 chat,交内核闸门追问。
    func classifyDispatch(_ prompt: String) async -> DispatchDecision {
        if isMinimalVoiceMode { return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil) }   // 极简语音:一律对话
        if LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction(prompt) {
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil)
        }
        // **关键词门降级**:不再 `return .task` 抄近路——只产出 actionHint 信号,既喂大脑当先验、又作为置信度的"外部锚"。
        // 大脑判 chat 但 actionHint 说像执行 → 冲突 → 压低置信 → 闸门追问(而非原来强判 task 硬覆盖大脑)。
        let actionHint = Self.isObviousExecutionRequest(prompt)

        let ctx = buildTriageContext()
        var threadBlock = ""
        if !ctx.threads.isEmpty {
            let lines = ctx.threads.map { "[\($0.label)] \($0.summary)" }.joined(separator: "\n")
            threadBlock = "\n【当前可续的任务线程】(用户可能在回答/延续其中某条,哪怕中间隔了几句别的话):\n\(lines)\n"
        }
        let far = ctx.far.isEmpty ? "" : "【更早对话摘要(压缩)】\n\(ctx.far)\n\n"
        let hintLine = actionHint ? "【先验线索】这条消息文面含明确动作动词,**很可能是要你执行的动作**(含**现实动作/外部操作**:同步到Notion/飞书、发邮件/发消息、查日历/查邮件、订票、控制设备/开关灯…)——**默认判 task**(没文件产出也算;派发后会去找能力/要授权再做,别因为「我可能没这能力」就判 chat)。**只有**它明显只是闲聊/解释里**提到**了这些词(如「教我怎么写爬虫」「解释下怎么发邮件」「谢谢你帮我发邮件」=解释/闲聊、不是要你现在做)才判 chat。\n" : ""
        let replyOut = ctx.threads.isEmpty ? "" : "、{\"kind\":\"reply\",\"thread\":\"T1\",\"confidence\":\"high\"}"
        let system = """
        你是分诊器。下面给你与用户的对话上下文(近期逐字 + 更早摘要)和当前可续的任务线程。
        判断用户【最新一条】消息属于哪一类,**并自报置信度 confidence(high/medium/low)**,只输出一行 JSON,不要任何解释:
        - reply:用户在【回答/延续/补充/确认】上面某条可续任务线程(尤其它标了"⏳正等你回答"、或在问主题/要信息/给选项)——**哪怕中间隔了几句闲聊也算**,指出是哪条 thread(如 "T1")。
        - chat:与任何任务线程无关、灵枢能**当场用语言就答完**的(闲聊/解释概念/问事实/给建议/介绍自己)。
        - task:与现有线程无关的**全新**执行任务。两类都算 task:① 有产出物的(做PPT/文档/代码/爬虫、要落盘、跑命令、多步);
          ② **现实动作 / 外部系统操作**(同步到 Notion/飞书/云盘、发邮件/发消息、查日历/查邮件、订票/订会议室、控制设备/开关灯/调温度、
          连接打印机/音箱、导入数据库…)——这类**没有文件产出**但要**真去做、真去连**,**哪怕你怀疑现在还没接入这个能力,也判 task**
          (派发后会去找能力/要授权再做),**绝不要因为"我可能做不到"就当 chat 去解释或拒绝**。
        \(hintLine)
        \(far)【近期对话(逐字)】
        \(ctx.near)
        \(threadBlock)
        输出:{"kind":"chat","confidence":"high"}、{"kind":"task","goal":"一句话总目标(高度概括)","confidence":"high"}\(replyOut)
        """
        let classifier = LingShuAgentSession(
            id: "triage-\(UUID().uuidString.prefix(6))",
            system: system, tools: [], model: controlPlaneModelAdapter(.triage), maxTurns: 1
        )
        let result = await classifier.send("用户最新消息:\(prompt)")
        guard case .completed(let raw) = result else {
            // **脑调用失败:不静默吞成 chat**——标记 brainFailed + 低置信,交内核闸门显式追问(而非假装闲聊敷衍)。
            return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil,
                                    confidence: .low, actionHint: actionHint, brainFailed: true)
        }
        let text = LingShuReasoningText.stripThinkTags(raw)
        let norm = text.lowercased().replacingOccurrences(of: " ", with: "")
        let brainConf = Self.parseConfidence(norm)
        if !ctx.threads.isEmpty, norm.contains("\"kind\":\"reply\"") || norm.contains("kind:reply") {
            let label = (Self.jsonField(text, "thread") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let rid = ctx.threads.first(where: { $0.label.uppercased() == label })?.recordID ?? ctx.threads.first?.recordID
            if let rid {
                return DispatchDecision(kind: .reply, goal: nil, replyRecordID: rid,
                                        confidence: brainConf, actionHint: actionHint)
            }
        }
        let isTask = norm.contains("\"kind\":\"task\"") || norm.contains("kind:task")
        let brainKind: DispatchKind = isTask ? .task : .chat
        let fused = Self.fuseConfidence(brainKind: brainKind, brainConf: brainConf, actionHint: actionHint)
        if isTask {
            let goal = Self.jsonField(text, "goal")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return DispatchDecision(kind: .task, goal: (goal?.isEmpty == false) ? goal : nil,
                                    replyRecordID: nil, confidence: fused, actionHint: actionHint)
        }
        return DispatchDecision(kind: .chat, goal: nil, replyRecordID: nil,
                                confidence: fused, actionHint: actionHint)
    }

    /// 解析大脑自报的置信度(没报 → medium 中性)。
    nonisolated static func parseConfidence(_ norm: String) -> DispatchConfidence {
        if norm.contains("\"confidence\":\"high\"") || norm.contains("confidence:high") { return .high }
        if norm.contains("\"confidence\":\"low\"") || norm.contains("confidence:low") { return .low }
        return .medium
    }

    /// **融合置信度**(图没说、但 GLM 自评不可靠必须补):大脑自报 × 关键词信号印证 × kind 一致性。
    /// - 关键词命中 且 大脑判 task → high(双印证)
    /// - 关键词命中 但 大脑判 chat → low(冲突:像执行却判闲聊 → 闸门追问,不静默放过)
    /// - 其余 → 信大脑自报(无外部信号可锚,不强行干预、避免误伤真任务)
    nonisolated static func fuseConfidence(brainKind: DispatchKind, brainConf: DispatchConfidence, actionHint: Bool) -> DispatchConfidence {
        if actionHint && brainKind == .task { return .high }
        if actionHint && brainKind == .chat { return .low }
        return brainConf
    }

    /// **内核校验闸门(图里 D)·第一步**:吃分诊决策,低置信/脑失败 → 返回「追问指令」(注入主回合,逼它先与用户确认意图,
    /// 不再静默吞成闲聊);高置信 → nil(照常按 kind 扇出)。把决策重心从 triage.kind 往统一闸门挪的起点。
    func kernelGateClarifyDirective(_ d: DispatchDecision) -> String? {
        if d.brainFailed {
            return "(系统提示:刚才对这条消息意图的判定没成功。请先用一句话跟用户确认他是想让你**执行某个任务**还是**只是聊聊**,确认后再行动,别擅自当闲聊敷衍。)"
        }
        if d.confidence == .low {
            return "(系统提示:这条消息意图不明确——可能是要执行的任务,也可能只是闲聊。先简短跟用户确认意图再决定怎么做,别直接当闲聊回应、也别擅自开跑任务。)"
        }
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

    /// 是否是明确的执行请求。这里保持**通用范式**:不识别具体平台,只识别动作结构。
    /// 目标是拦住"把/请/帮我 + 动作 + 对象"、路径/产出物/外设/外部系统操作等清晰任务,
    /// 同时放过"什么是/解释/为什么"这类纯问答。
    nonisolated static func isObviousExecutionRequest(_ prompt: String) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let compact = text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")

        if isPureExplanationQuestion(compact) { return false }
        if isContinuationOnly(compact) { return false }
        if ["提醒我", "明天提醒", "后提醒", "定时提醒"].contains(where: { compact.contains($0) }) {
            return true
        }

        let actionVerbs = [
            "写", "做", "生成", "创建", "新建", "修改", "修复", "删除", "保存", "导出", "转换",
            "打开", "关闭", "运行", "执行", "构建", "测试", "部署", "安装", "卸载",
            "同步", "上传", "下载", "发送", "发布", "提交", "连接", "接入", "调用",
            "扫描", "检索", "索引", "搜索", "查找", "找出", "定位", "读取", "整理",
            "总结", "概括", "分析", "提炼", "归纳", "改写", "翻译",
            "控制", "播放", "朗读", "播报", "设置", "设定", "安排",
            "write", "create", "make", "generate", "update", "modify", "fix", "delete", "save",
            "export", "convert", "open", "run", "execute", "build", "test", "deploy", "install",
            "sync", "upload", "download", "send", "post", "submit", "connect", "call", "scan",
            "search", "find", "index", "read", "control", "play", "schedule"
        ]
        let hasActionVerb = actionVerbs.contains { compact.contains($0) }
        guard hasActionVerb else { return false }

        let imperativeHints = [
            "把", "将", "给我", "帮我", "替我", "为我", "请", "需要你", "我要你", "让灵枢",
            "在目录", "保存到", "输出到", "同步到", "上传到", "发送给", "写入", "运行一下",
            "please", "can you", "could you", "let's"
        ]
        let objectHints = [
            "/", ".py", ".txt", ".md", ".ppt", ".pptx", ".pdf", ".docx", ".xlsx", ".csv", ".html",
            "文件", "附件", "上传", "目录", "路径", "项目", "代码", "脚本", "文档", "ppt", "pdf", "网页", "浏览器",
            "本机", "电脑", "网络", "设备", "摄像头", "麦克风", "音箱", "电视", "盒子",
            "外部", "第三方", "api", "token", "授权", "凭据", "知识库", "notion", "飞书", "钉钉"
        ]
        if imperativeHints.contains(where: { compact.contains($0) }) { return true }
        if objectHints.contains(where: { compact.contains($0) }) { return true }

        // 祈使短句:以动作开头,通常是任务,比如"扫描局域网设备"、"生成三页PPT"。
        return actionVerbs.contains { compact.hasPrefix($0) }
    }

    nonisolated static func executionGoalSummary(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 96 else { return trimmed }
        return String(trimmed.prefix(96)) + "..."
    }

    nonisolated private static func isPureExplanationQuestion(_ compact: String) -> Bool {
        let prefixes = [
            "什么是", "啥是", "解释一下", "介绍一下", "讲讲", "说说", "为什么", "为何",
            "如何理解", "怎么理解", "区别是什么", "是什么意思", "你是谁", "我是谁",
            "what is", "explain", "why"
        ]
        if prefixes.contains(where: { compact.hasPrefix($0) }) { return true }
        let directAnswerMarkers = [
            "给我一句话", "用一句话", "一句话说明", "一句话解释", "一句话提醒",
            "只回答", "直接回答", "简要说明", "简单说", "一句话说"
        ]
        if directAnswerMarkers.contains(where: { compact.contains($0) }),
           !["保存到", "写入", "输出到", "同步到", "发送给", "上传到", "运行", "打开", "扫描",
             "设置提醒", "设定提醒", "提醒我", "定时", "明天提醒", "后提醒"].contains(where: { compact.contains($0) }) {
            return true
        }
        // "能不能/是否/有没有"本身不是任务;但如果后面带"帮我/替我/把/将/在目录/保存到"等动作结构,
        // 上面的前缀不拦,交给执行硬门判。
        let capabilityQuestions = ["能不能", "是否可以", "可不可以", "有没有可能"]
        if capabilityQuestions.contains(where: { compact.hasPrefix($0) }),
           !["帮我", "替我", "把", "将", "在目录", "保存到", "同步到", "运行"].contains(where: { compact.contains($0) }) {
            return true
        }
        return false
    }

    nonisolated private static func isContinuationOnly(_ compact: String) -> Bool {
        let controls = ["继续", "接着", "下一步", "停", "停止", "暂停", "取消", "重试", "用第一个", "选a", "选b"]
        return controls.contains(compact)
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
                              extraCheckerAgentIDs: [String] = []) -> String {
        installAgentEventSinkIfNeeded()
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
        let tools = withPhaseTracking(   // 相位跟踪:派发任务也驱动本体显示理解/规划/执行/验收(光球随环节变色变脉动)
            // 继承父上下文的 shell 预授权:在岗/自主完整授权时给 autoAllowShell,否则派发任务跑 shell 会卡在审批框(见 dispatchedTaskExecutionPolicy)。
            agentBuiltinTools(recordIDProvider: recordProvider, executionPolicy: dispatchedTaskExecutionPolicy)
            + [Self.timeTool(), Self.locationTool(), Self.webSearchTool(), recallMemoryTool(), Self.askUserTool(),
               findImagesTool(), acquireResourceTool(),
               updateTaskPlanTool(recordIDProvider: recordProvider), reviewDesignTool(recordIDProvider: recordProvider), speakTool(), digitalHumanTool(), enterManagedModeTool()]
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
            ④ **铁律:你只管开发,绝不自己调 `run_agent` 去找别的 agent 验收 / 复核**——独立 checker 由系统在你交付后**自动**跑,不归你管;你交付后就结束回合。
            """))
        }
        let sub = makeAgentSession(
            id: subID,
            system: Self.dispatchedTaskSystemPrompt(workingDir: agentWorkingDirectory),
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
            if await orchestrator.spawnDetached(id: subID, objective: prompt, session: sub) { return }   // 有空位,直接派出
            // 满并发上限(N=3)→ **不直接拒绝用户任务,改排队**:轮询等空位再自动派出(bubble 保持加载=排队中)。
            // 老练度补齐(2026-06-19):用户快速连发几条任务时旧逻辑直接拒"重发一次"体验差;改为自动排队续派。
            // (注:模型自己 spawn_task 的路径仍保持硬背压不变——那是防模型一次甩几十个子任务 runaway,与用户连发不同。)
            for _ in 0..<300 {   // 最长约 10 分钟(每 2s 查一次空位)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.agentSubTaskRecords[subID] != nil else { return }   // 已被取消/清掉 → 停止排队
                if await orchestrator.spawnDetached(id: subID, objective: prompt, session: sub) { return }   // 轮到了,编排器事件接管 bubble
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
        let pending = ChatMessage(speaker: "灵枢", text: dialogueAcknowledgement.intake(for: prompt), isUser: false, isLoading: true, taskRecordID: recordID)
        chatMessages.append(pending)
        dispatchedTaskBubbles[recordID] = pending.id   // 完成由编排器事件回填这条气泡
        submitTaskFollowup(prompt, recordID: recordID) // 隔离子任务 → orchestrator.resumeWithInput(续那条会话)
    }

    /// 回填某条派发任务的加载气泡(完成/失败/背压时用);找不到就追加一条。回填后清掉映射。
    func fillDispatchedBubble(_ recordID: String, text: String) {
        let shouldAwaitUser = dispatchedRecordNeedsUserInput(recordID)
        let choices = LingShuChoiceParsing.parse(text)
            ?? (shouldAwaitUser ? userPrerequisiteChoicePromptIfNeeded(resultText: text, taskRecordID: recordID) : nil)
        let awaitingRecordID = shouldAwaitUser ? recordID : nil
        if let bubbleID = dispatchedTaskBubbles[recordID],
           let idx = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[idx].text = text
            chatMessages[idx].isLoading = false
            chatMessages[idx].choices = choices
            chatMessages[idx].awaitingInputForRecordID = awaitingRecordID
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false, taskRecordID: recordID,
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
        Task { await agentOrchestrator.resumeWithInput(id: subID, input: resumeInput) }
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
