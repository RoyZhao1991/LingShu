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
            // 每条并行子任务 = 一条独立任务执行记录(列表里有自己的任务号)。
            let recordID = createTaskExecutionRecord(for: objective)
            agentSubTaskRecords[id] = recordID
            appendTaskRecordMessage(recordID, actor: "Agent循环", role: "派生子任务", kind: .router, text: "主会话派生并行子任务:\(objective)")
        case .completed(let id, let objective, let summary):
            if let recordID = agentSubTaskRecords[id] {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "结果", kind: .result, text: summary)
                finishTaskRecord(recordID, status: .completed, summary: summary)
            }
            chatMessages.append(.init(speaker: "灵枢", text: "✅ 子任务「\(objective)」完成:\(summary)", isUser: false, taskRecordID: agentSubTaskRecords[id]))
            briefMainThread("子任务「\(objective)」已完成:\(summary.prefix(200))")
        case .blocked(let id, let objective, let question):
            if let recordID = agentSubTaskRecords[id] {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "卡住", kind: .warning, text: question)
            }
            chatMessages.append(.init(speaker: "灵枢", text: "⏸ 子任务「\(objective)」卡住,需要你定:\(question)", isUser: false, taskRecordID: agentSubTaskRecords[id]))
            briefMainThread("子任务「\(objective)」卡住,等待用户补充:\(question.prefix(160))")
        case .failed(let id, let objective, let summary):
            if let recordID = agentSubTaskRecords[id] {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "失败", kind: .warning, text: summary)
                finishTaskRecord(recordID, status: .blocked, summary: summary)
            }
            chatMessages.append(.init(speaker: "灵枢", text: "⚠️ 子任务「\(objective)」未能自行收尾:\(summary)", isUser: false, taskRecordID: agentSubTaskRecords[id]))
            briefMainThread("子任务「\(objective)」未能自行收尾:\(summary.prefix(160))")
        }
    }

    /// 子任务进展回灌主线程(信息同步,非完整上下文):只把**简报摘要**注入常驻主会话,
    /// 主线程下次作答即知悉,不搬子任务的完整 transcript(对齐 codex 的 subagent 汇报)。
    func briefMainThread(_ brief: String) {
        let session = mainAgentSessionHolder
        Task { await session?.injectBriefing(brief) }
    }
}
