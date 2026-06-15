import Foundation

/// 编排器事件桥接子域:把 `LingShuAgentOrchestrator` 的子任务事件接到 UI(独立任务记录 + 对话回灌),
/// 并在子任务收尾时把**简报**回灌主线程(信息同步,非完整上下文)。从 AgentBackbone 拆出,各管一段。
@MainActor
extension LingShuState {

    /// 把编排器事件桥接到 UI:子任务建成独立任务记录(任务号 + 列表),结果/卡住/失败回灌对话 + 简报主线程。
    func installAgentEventSinkIfNeeded() {
        guard !agentEventSinkInstalled else { return }
        agentEventSinkInstalled = true
        let orchestrator = agentOrchestrator
        Task { await orchestrator.setEventSink { @MainActor [weak self] event in
            self?.handleOrchestratorEvent(event)
        } }
        // 子任务也接验收门:复用 verifyAgentDeliverable(独立 verifier + 真实落盘核对)。
        Task { await orchestrator.setVerifyHook { @MainActor [weak self] subID, objective, reply in
            guard let self else { return (true, "") }
            return await self.verifyAgentDeliverable(userRequest: objective, reply: reply, taskRecordID: self.agentSubTaskRecords[subID])
        } }
    }

    func handleOrchestratorEvent(_ event: LingShuOrchestratorEvent) {
        switch event {
        case .spawned(let id, let objective):
            // 主线程分诊派发的任务已**预映射**到自己的记录(dispatchIsolatedTask),复用之;否则(模型 spawn_task)新建一条。
            let recordID = agentSubTaskRecords[id] ?? createTaskExecutionRecord(for: objective)
            agentSubTaskRecords[id] = recordID
            appendTaskRecordMessage(recordID, actor: "Agent循环", role: "派生子任务", kind: .router, text: "派生并行子任务:\(objective)")
        case .completed(let id, let objective, let summary):
            let recordID = agentSubTaskRecords[id]
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "结果", kind: .result, text: summary)
                finishTaskRecord(recordID, status: .completed, summary: summary)
            }
            postOrchestratorChat(recordID: recordID, dispatched: "✅ \(summary)", spawned: "✅ 子任务「\(objective)」完成:\(summary)")
            briefMainThread("子任务「\(objective)」已完成:\(summary.prefix(200))")
        case .blocked(let id, let objective, let question):
            let recordID = agentSubTaskRecords[id]
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "卡住", kind: .warning, text: question)
            }
            postOrchestratorChat(recordID: recordID, dispatched: "⏸ 卡住,需要你定:\(question)", spawned: "⏸ 子任务「\(objective)」卡住,需要你定:\(question)")
            briefMainThread("子任务「\(objective)」卡住,等待用户补充:\(question.prefix(160))")
        case .failed(let id, let objective, let summary):
            let recordID = agentSubTaskRecords[id]
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "失败", kind: .warning, text: summary)
                finishTaskRecord(recordID, status: .blocked, summary: summary)
            }
            postOrchestratorChat(recordID: recordID, dispatched: "⚠️ 未能自行收尾:\(summary)", spawned: "⚠️ 子任务「\(objective)」未能自行收尾:\(summary)")
            briefMainThread("子任务「\(objective)」未能自行收尾:\(summary.prefix(160))")
        }
    }

    /// 编排器结果回灌对话:**主线程分诊派发**的任务回填它自己的加载气泡(不另起一条);
    /// **模型 spawn_task** 的子任务则追加一条新气泡(它本就没有预建气泡)。
    private func postOrchestratorChat(recordID: String?, dispatched: String, spawned: String) {
        if let recordID, dispatchedTaskBubbles[recordID] != nil {
            fillDispatchedBubble(recordID, text: dispatched)
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: spawned, isUser: false, taskRecordID: recordID))
        }
    }

    /// 子任务进展回灌主线程(信息同步,非完整上下文):只把**简报摘要**注入常驻主会话,
    /// 主线程下次作答即知悉,不搬子任务的完整 transcript(对齐 codex 的 subagent 汇报)。
    func briefMainThread(_ brief: String) {
        let session = mainAgentSessionHolder
        Task { await session?.injectBriefing(brief) }
    }
}
