import Foundation

/// 主线程分诊(Stage 2 多任务真隔离的第一步):灵枢收到消息后**先判**能否直接对话作答(chat),
/// 还是需要派发执行(task)。chat 留主线程(连续对话);task 派发独立隔离 session 并行跑。
/// 旧的「启发式前置门」在 82fc503 被删,这里在现代 agent loop 之上重建一个轻量分诊。
@MainActor
extension LingShuState {

    /// 一次轻量模型判定(无工具、单回合)。task 时附一句话总目标。
    /// **保守**:判定失败/解析不出 → 当 chat(留主线程),绝不把普通对话误派成任务。
    func classifyDispatch(_ prompt: String) async -> (dispatch: Bool, goal: String?) {
        // 极简语音对话模式:一律当对话,不分诊、不派发(用户硬性要求)。
        if isMinimalVoiceMode { return (false, nil) }

        let classifier = LingShuAgentSession(
            id: "triage-\(UUID().uuidString.prefix(6))",
            system: """
            你是分诊器。判断用户这条消息属于哪一类,**只输出一行 JSON,不要任何解释**:
            - chat:灵枢能直接对话/问答完成(闲聊、解释概念、问事实、给建议、简单查询、介绍自己),无需写文件/跑命令/多步执行。
            - task:需要执行的任务(做 PPT/文档/代码/爬虫/系统、要落盘产出物、要跑命令、明显多步推进)。
            输出:{"kind":"chat"} 或 {"kind":"task","goal":"一句话总目标(高度概括,如「构建一个清分结算系统」)"}
            """,
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await classifier.send(prompt)
        guard case .completed(let raw) = result else { return (false, nil) }
        let text = LingShuReasoningText.stripThinkTags(raw)
        // 宽松解析:命中 "task" 类即派发,否则(含解析失败)留主线程。
        let normalized = text.lowercased().replacingOccurrences(of: " ", with: "")
        let isTask = normalized.contains("\"kind\":\"task\"") || normalized.contains("kind:task")
        guard isTask else { return (false, nil) }
        let goal = Self.jsonField(text, "goal")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, (goal?.isEmpty == false) ? goal : nil)
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
        let tools = agentBuiltinTools(recordIDProvider: recordProvider)
            + [Self.timeTool(), Self.webSearchTool(), recallMemoryTool(), Self.askUserTool(),
               findImagesTool(), acquireResourceTool(),
               updateTaskPlanTool(recordIDProvider: recordProvider), reviewDesignTool(recordIDProvider: recordProvider), speakTool(), digitalHumanTool()]
            + previewTools()
        // 注入"最近产出物"上下文:让"运行起来/继续/改一下"这类派发任务接得上(知道刚做了什么、在哪、怎么跑),
        // 不再重新扫工作目录瞎猜(根治"超级玛丽做完了却问我要运行哪个项目")。
        let deliverCtx = recentDeliverablesContext()
        let sub = LingShuAgentSession(
            id: subID,
            system: Self.dispatchedTaskSystemPrompt(workingDir: codexWorkingDirectory),
            initialMessages: deliverCtx.isEmpty ? [] : [.init(role: .system, content: deliverCtx)],
            tools: tools,
            model: adapter,
            // 安全天花板(防失控),非目标预算——复杂工程的「读→改→构建→测试→修」单段推进
            // 真能远超 40 步(超级玛丽暴露:40 太低,撞顶就被当失败/异常收尾)。抬到 120 让它纯做防失控用;
            // 真停止位仍是目标达成/停滞(5 次重复)/撞顶后由 verifyAndContinue 续跑恢复(见编排器委托)。
            maxTurns: 120
        )
        let orchestrator = agentOrchestrator
        Task { @MainActor [weak self] in
            let admitted = await orchestrator.spawnDetached(id: subID, objective: prompt, session: sub)
            guard let self, !admitted else { return }
            // 满 3 条并行(背压):如实回填,不无限 loading。
            self.fillDispatchedBubble(taskRecordID, text: "当前已有 3 个任务在并行(上限),这条先没派出去——等一条完成或重发一次。")
            self.agentSubTaskRecords[subID] = nil
        }
        return pending.text
    }

    /// 回填某条派发任务的加载气泡(完成/失败/背压时用);找不到就追加一条。回填后清掉映射。
    func fillDispatchedBubble(_ recordID: String, text: String) {
        if let bubbleID = dispatchedTaskBubbles[recordID],
           let idx = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[idx].text = text
            chatMessages[idx].isLoading = false
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false, taskRecordID: recordID))
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
        - 完成后用一句话给结果 + 关键产出物绝对路径。不暴露内部工具名/机制词。
        """
    }
}
