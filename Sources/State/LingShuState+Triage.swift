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

    /// **上下文感知**的轻量分诊(用户定调 2026-06-17):每次分诊都带上**完整语义的近上下文(最近逐字)+ 压缩的远上下文
    /// (对话摘要)+ 当前可续的派发任务线程**,让分诊器能(a)分得更准、(b)**回溯到前面隔了几条才问的问题**——
    /// 用户回答某条任务线程的提问(哪怕中间穿插了几句闲聊)也能认出来、续到**那条隔离会话本身**。
    /// 返回 reply 时附 `replyRecordID`(要续的那条派发线程记录)。**保守**:判不出 → chat(留主线程),不误派。
    func classifyDispatch(_ prompt: String) async -> (kind: DispatchKind, goal: String?, replyRecordID: String?) {
        if isMinimalVoiceMode { return (.chat, nil, nil) }   // 极简语音:一律对话

        let ctx = buildTriageContext()
        var threadBlock = ""
        if !ctx.threads.isEmpty {
            let lines = ctx.threads.map { "[\($0.label)] \($0.summary)" }.joined(separator: "\n")
            threadBlock = "\n【当前可续的任务线程】(用户可能在回答/延续其中某条,哪怕中间隔了几句别的话):\n\(lines)\n"
        }
        let far = ctx.far.isEmpty ? "" : "【更早对话摘要(压缩)】\n\(ctx.far)\n\n"
        let replyOut = ctx.threads.isEmpty ? "" : "、{\"kind\":\"reply\",\"thread\":\"T1\"}"
        let system = """
        你是分诊器。下面给你与用户的对话上下文(近期逐字 + 更早摘要)和当前可续的任务线程。
        判断用户【最新一条】消息属于哪一类,**只输出一行 JSON,不要任何解释**:
        - reply:用户在【回答/延续/补充/确认】上面某条可续任务线程(尤其它标了"⏳正等你回答"、或在问主题/要信息/给选项)——**哪怕中间隔了几句闲聊也算**,指出是哪条 thread(如 "T1")。
        - chat:与任何任务线程无关、灵枢能直接对话作答(闲聊/解释概念/问事实/给建议/介绍自己)。
        - task:与现有线程无关的**全新**执行任务(做PPT/文档/代码/爬虫、要落盘产出物、跑命令、明显多步)。

        \(far)【近期对话(逐字)】
        \(ctx.near)
        \(threadBlock)
        输出:{"kind":"chat"}、{"kind":"task","goal":"一句话总目标(高度概括)"}\(replyOut)
        """
        let classifier = LingShuAgentSession(
            id: "triage-\(UUID().uuidString.prefix(6))",
            system: system, tools: [], model: makeAgentModelAdapter(), maxTurns: 1
        )
        let result = await classifier.send("用户最新消息:\(prompt)")
        guard case .completed(let raw) = result else { return (.chat, nil, nil) }
        let text = LingShuReasoningText.stripThinkTags(raw)
        let norm = text.lowercased().replacingOccurrences(of: " ", with: "")
        if !ctx.threads.isEmpty, norm.contains("\"kind\":\"reply\"") || norm.contains("kind:reply") {
            let label = (Self.jsonField(text, "thread") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let rid = ctx.threads.first(where: { $0.label.uppercased() == label })?.recordID ?? ctx.threads.first?.recordID
            if let rid { return (.reply, nil, rid) }
        }
        let isTask = norm.contains("\"kind\":\"task\"") || norm.contains("kind:task")
        guard isTask else { return (.chat, nil, nil) }
        let goal = Self.jsonField(text, "goal")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (.task, (goal?.isEmpty == false) ? goal : nil, nil)
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
    @discardableResult
    func dispatchIsolatedTask(prompt: String, taskRecordID: String, goal: String?) -> String {
        installAgentEventSinkIfNeeded()
        interruptSpeechOutput?()
        let subID = "task-\(UUID().uuidString.prefix(6))"
        agentSubTaskRecords[subID] = taskRecordID   // 预映射:.spawned 据此复用这条记录,不另建
        if let goal, !goal.isEmpty, let i = taskExecutionRecords.firstIndex(where: { $0.id == taskRecordID }) {
            taskExecutionRecords[i].goal = goal
            persistTaskExecutionRecords()
        }
        let pending = ChatMessage(speaker: "灵枢", text: dialogueAcknowledgement.intake(for: prompt), isUser: false, isLoading: true, taskRecordID: taskRecordID)
        chatMessages.append(pending)
        dispatchedTaskBubbles[taskRecordID] = pending.id
        appendTrace(kind: .route, actor: "主线程分诊", title: "派发隔离任务", detail: "判为执行任务,派生独立隔离 session 并行推进(不进主对话上下文)。")

        let adapter = makeAgentModelAdapter()
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
        let sub = makeAgentSession(
            id: subID,
            system: Self.dispatchedTaskSystemPrompt(workingDir: codexWorkingDirectory),
            initialMessages: combinedCtx.isEmpty ? [] : [.init(role: .system, content: combinedCtx)],
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
        return pending.text
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
        let choices = LingShuChoiceParsing.parse(text)   // 卡住要你定+枚举选项 → 壳渲染成可点击;否则 nil
        if let bubbleID = dispatchedTaskBubbles[recordID],
           let idx = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[idx].text = text
            chatMessages[idx].isLoading = false
            chatMessages[idx].choices = choices
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false, taskRecordID: recordID, choices: choices))
        }
        dispatchedTaskBubbles[recordID] = nil
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
        - **定时/提醒/"每天X点"/"过一会儿提醒我"这类时间点触发,用 `schedule_task`(原生定时四肢,真持久化、到点把指令交回完整的我处理)——绝不写 launchd plist / crontab / shell 脚本假装设了定时(那是只写文件没接到系统的假象)。等"外部条件满足"才继续则用 `watch_until`。`list_scheduled_tasks`/`cancel_scheduled_task` 管理。
        - **要当面占屏实时演示 / 与主人实时互动答疑 / 接管屏幕操作时**:别自己直接 present_fullscreen 占屏——**先调 `enter_managed_mode`**(写清要实时做什么 + 文件绝对路径),它会弹窗征主人同意;同意后由托管会话接手实时演示/互动,你这条到此交接。普通做事(生成 PPT/写文件/查资料)不必调它。
        - 完成后用一句话给结果 + 关键产出物绝对路径。不暴露内部工具名/机制词。
        """
    }
}
