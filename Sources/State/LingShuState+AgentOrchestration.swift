import Foundation

/// 编排器事件桥接子域:把 `LingShuAgentOrchestrator` 的子任务事件接到 UI(独立任务记录 + 对话回灌),
/// 并在子任务收尾时把**简报**回灌主线程(信息同步,非完整上下文)。从 AgentBackbone 拆出,各管一段。
@MainActor
extension LingShuState {

    /// 把编排器事件桥接到 UI:子任务建成独立任务记录(任务号 + 列表),结果/卡住/失败回灌对话 + 简报主线程。
    func installAgentEventSinkIfNeeded() {
        guard !agentEventSinkInstalled else { return }
        agentEventSinkInstalled = true
        startConnectivityMonitorIfNeeded()
        loadDeliverablesIfNeeded()   // 从增量存储恢复最近产出物(跨重启续上"运行起来/继续")+ 启定时压缩
        let orchestrator = agentOrchestrator
        Task { await orchestrator.setEventSink { @MainActor [weak self] event in
            self?.handleOrchestratorEvent(event)
        } }
        // 子任务也接**验收 + 恢复**:委托主线程统一的 verifyAndContinue(撞顶恢复 + 多轮验收 + 测试/运行门 + 停滞交还),
        // 子任务与主线程同一套执行恢复力——复杂工程撞顶/崩溃会自己续跑修到跑通,而非直接判异常。
        Task { await orchestrator.setAcceptanceHook { @MainActor [weak self] subID, objective, session, initial in
            guard let self else { return initial }
            return await self.verifyAndContinue(session: session, result: initial, userRequest: objective, taskRecordID: self.agentSubTaskRecords[subID])
        } }
    }

    func handleOrchestratorEvent(_ event: LingShuOrchestratorEvent) {
        // 派发任务进入终态(完成/失败/卡住/中断)→ 收掉 LOOP 相位,别让本体停在"执行中"不灭。
        switch event {
        case .completed, .failed, .blocked, .interrupted: setLoopPhase(.idle)
        default: break
        }
        switch event {
        case .spawned(let id, let objective):
            // 主线程分诊派发的任务已**预映射**到自己的记录(dispatchIsolatedTask),复用之;否则(模型 spawn_task)新建一条。
            let recordID = agentSubTaskRecords[id] ?? createTaskExecutionRecord(for: objective)
            agentSubTaskRecords[id] = recordID
            appendTaskRecordMessage(recordID, actor: "灵枢", role: "派生子任务", kind: .router, text: "派生并行子任务:\(objective)")
        case .completed(let id, let objective, let summary):
            let recordID = agentSubTaskRecords[id]
            if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }   // 收尾即解除"等回答"
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "结果", kind: .result, text: summary)
                finishTaskRecord(recordID, status: .completed, summary: summary)
                recordDeliverable(recordID: recordID, title: objective, summary: summary)   // 登记产出物供"运行起来/继续"接上
            }
            briefMainThread("子任务「\(objective)」已完成:\(summary.prefix(200))")
            promoteSubtaskKnowledge(objective: objective, summary: summary)   // M3:子线程知识蒸馏进常驻主脑(v2),事后主线程可召回
            // **完成汇报时机(用户定调 2026-06-19,通用):一律入待汇报队列,由 drain 择机发——互动中捎带下次主线程汇报、待机则主动出声。**
            deliverOrQueueSubtaskReport(recordID: recordID, objective: objective, summary: summary)
        case .blocked(let id, let objective, let question):
            let recordID = agentSubTaskRecords[id]
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "卡住", kind: .warning, text: question)
                blockedDispatchedRecordID = recordID   // 等用户回答→下条主输入直接续这条隔离会话(不重新分诊)
            }
            postOrchestratorChat(recordID: recordID, dispatched: "⏸ 卡住,需要你定:\(question)", spawned: "⏸ 子任务「\(objective)」卡住,需要你定:\(question)")
            briefMainThread("子任务「\(objective)」卡住,等待用户补充:\(question.prefix(160))")
        case .failed(let id, let objective, let summary):
            let recordID = agentSubTaskRecords[id]
            if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "失败", kind: .warning, text: summary)
                finishTaskRecord(recordID, status: .blocked, summary: summary)
            }
            postOrchestratorChat(recordID: recordID, dispatched: "⚠️ 未能自行收尾:\(summary)", spawned: "⚠️ 子任务「\(objective)」未能自行收尾:\(summary)")
            briefMainThread("子任务「\(objective)」未能自行收尾:\(summary.prefix(160))")
        case .interrupted(let id, let objective, let reason):
            // 网络/网关中断:**非失败**,标"已暂停",启动主动重试循环(它在主对话框统一展示重试进度,故这里不另发对话气泡)。
            _ = objective
            let recordID = agentSubTaskRecords[id]
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "暂停", kind: .warning, text: "网络中断,已暂停:\(reason)")
                finishTaskRecord(recordID, status: .suspended, summary: "网络中断已暂停,联网后自动续跑。")
            }
            startNetworkRetryLoopIfNeeded()
        case .resumed(let id, let objective):
            // 重连/手动续接:从"已暂停"翻回"执行中",执行流继续追加进该记录窗口。
            let recordID = agentSubTaskRecords[id]
            if let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) {
                taskExecutionRecords[idx].status = .running
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "续跑", kind: .router, text: "网络恢复,自动接着跑。")
                persistTaskExecutionRecords()
            }
            _ = objective
        }
    }

    /// 编排器结果回灌对话:**主线程分诊派发**的任务回填它自己的加载气泡(不另起一条);
    /// **模型 spawn_task** 的子任务则追加一条新气泡(它本就没有预建气泡)。
    private func postOrchestratorChat(recordID: String?, dispatched: String, spawned: String) {
        if let recordID, dispatchedTaskBubbles[recordID] != nil {
            fillDispatchedBubble(recordID, text: dispatched)
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: spawned, isUser: false, taskRecordID: recordID, choices: LingShuChoiceParsing.parse(spawned)))
        }
    }

    /// 此刻是否"在和主人互动/占屏中"(演示开着 / 在飞回合 / 正在朗读)——用于决定子任务完成汇报是**捎带**(别打断)还是**主动出声**。
    var isEngagedInInteraction: Bool {
        previewController.isPresented || hasActiveModelCall || autonomousRunTask != nil || (voiceManager?.isSpeakingOrQueued == true)
    }

    /// 子任务完成 → **一律入待汇报队列**(回填它的派发气泡作记录、并标记已念以抑制自动朗读=不在此刻打断互动)。
    /// 真正的汇报由 drain 择机发:互动中捎带下次主线程回复(finishAutonomousRun)、待机时主动出声(deliverPendingReportsIfIdle)。
    func deliverOrQueueSubtaskReport(recordID: String?, objective: String, summary: String) {
        let report = "你交代的「\(objective)」我做好了:\(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))"
        if pendingSubtaskReports.isEmpty { firstPendingReportAt = Date() }   // 本批第一个完成,记起点(防抖上限用)
        lastSubtaskReportEnqueuedAt = Date()                                 // 刷新"最近完成"时刻(防抖:接连完成的合并)
        pendingSubtaskReports.append(String(report))
        if let recordID, let bid = dispatchedTaskBubbles[recordID] {
            fillDispatchedBubble(recordID, text: "✅ \(summary)")   // 回填,别让派发气泡空转
            lastSpokenMessageID = bid                                // 标记已念→抑制自动朗读,汇报择机由 drain 统一发
        }
        appendTrace(kind: .system, actor: "灵枢", title: "子任务完成·入待汇报队列", detail: String(report.prefix(36)))
    }

    /// 取出并清空待汇报队列(供"捎带"拼进主线程回复)。多条**合并**成一条:单条直接;多条加序号,免零散乱。
    func drainPendingSubtaskReports() -> String {
        guard !pendingSubtaskReports.isEmpty else { return "" }
        let items = pendingSubtaskReports
        pendingSubtaskReports.removeAll()
        firstPendingReportAt = nil
        if items.count == 1 { return items[0] }
        let numbered = items.enumerated().map { "\($0.offset + 1)、\($0.element)" }.joined(separator: " ")
        return "刚才你交代的几件都办好了:\(numbered)"
    }

    /// 待机时主动汇报待汇报队列(贴气泡→自动朗读=主动出声)。在自主 1s 自驱循环里每拍调。
    /// **单线程顺序 + 合并接连完成**:① 正在念报告/互动中(`isEngagedInInteraction` 含 isSpeakingOrQueued)→ 不发,攒着(下一条等当前念完);
    /// ② **防抖合并**:最近一次完成后等 ~2.5s 稳定(其间又完成的一并并入)再一起报,免一个个零散刷;最长等 12s 兜底必发。
    func deliverPendingReportsIfIdle() {
        guard isStandingPersonOnDuty, !pendingSubtaskReports.isEmpty, !isEngagedInInteraction else { return }
        let now = Date()
        let stable = now.timeIntervalSince(lastSubtaskReportEnqueuedAt) >= 2.5    // 队列稳定(无新完成)= 这批接连完成的已到齐
        let maxWaited = firstPendingReportAt.map { now.timeIntervalSince($0) >= 12 } ?? false   // 兜底:别因持续 trickle 永远不报
        guard stable || maxWaited else { return }
        let text = drainPendingSubtaskReports()
        chatMessages.append(.init(speaker: "灵枢", text: "✅ \(text)", isUser: false))   // 末条灵枢气泡→ speakLatestReplyIfNeeded 自动朗读=主动汇报
        appendTrace(kind: .result, actor: "灵枢", title: "主动汇报(待机)", detail: String(text.prefix(40)))
    }

    /// 子任务进展回灌主线程(信息同步,非完整上下文):只把**简报摘要**注入常驻主会话,
    /// 主线程下次作答即知悉,不搬子任务的完整 transcript(对齐 codex 的 subagent 汇报)。
    func briefMainThread(_ brief: String) {
        let session = mainAgentSessionHolder
        Task { await session?.injectBriefing(brief) }
    }

    // MARK: - 断网重连自动续跑

    /// 懒启动网络可达性监控(首次有 agent 活动时):不可达→可达(去抖后)→ 回 MainActor 续跑所有暂停的任务。
    func startConnectivityMonitorIfNeeded() {
        guard connectivityMonitor == nil else { return }
        let monitor = LingShuConnectivityMonitor(onReconnect: { [weak self] in
            // 链路恢复:唤醒主动重试循环立即再试(重置退避),而不是直接续跑——让重试进度在对话框可见。
            Task { @MainActor in self?.triggerImmediateNetworkRetry() }
        })
        connectivityMonitor = monitor
        monitor.start()
    }

    /// 网络恢复:让编排器逐条从中断处续跑暂停的子任务,并续跑可能挂起的主会话回合。
    func resumeSuspendedWork() async {
        let ids = await agentOrchestrator.suspendedIDs()
        if !ids.isEmpty {
            appendTrace(kind: .route, actor: "网络", title: "重连", detail: "网络恢复,自动续跑 \(ids.count) 条暂停任务。")
        }
        for id in ids { await agentOrchestrator.resumeInterrupted(id: id) }
        await resumeSuspendedMainTurnIfNeeded()
        await resumeSuspendedAutonomousIfNeeded()
    }

    /// 续跑因断网挂起的**主会话**回合:从中断处 continueLoop() + 再过验收,把结果填回原气泡;
    /// 若续跑又因网络 .interrupted,则保留挂起态等下次重连。
    func resumeSuspendedMainTurnIfNeeded() async {
        guard let pending = suspendedMainTurn else { return }
        suspendedMainTurn = nil
        appendTrace(kind: .route, actor: "网络", title: "续跑主回合", detail: "网络恢复,接着把上一条跑完。")
        let session = await mainAgentSession()
        var result = await session.continueLoop()
        result = await verifyAndContinue(session: session, result: result, userRequest: pending.prompt, taskRecordID: pending.recordID)
        if case .interrupted = result {
            suspendedMainTurn = pending   // 还是连不上,继续挂起等下次重连
            return
        }
        finalizeMainTurn(result: result, bubbleID: pending.bubbleID, recordID: pending.recordID, prompt: pending.prompt, startedAt: pending.startedAt)
    }
}
