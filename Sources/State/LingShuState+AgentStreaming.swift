import Foundation

/// **统一 agent 流式范式(用户定调 2026-06-26:所有 agent 接入都流式,没流式的别干等,体验太差)**。
/// 任何把活外包给已注册 agent(codex / claude / …)且产出要进任务时间线的地方,都走 `runAgentStreamingToRecord`——
/// 它先落一条"执行中"参与方气泡,**边跑边把 agent 的输出尾部更新进同一条气泡**(对齐 codex/claude 的流式体验),
/// 不再静默干等到跑完才一次性出结果。角色管线 / 独立 checker / maker 返工都接它。
@MainActor
extension LingShuState {

    /// 按 ID 更新任务记录里某条消息的文本(流式增量更新同一条气泡用;不每块持久化,收尾再存,免高频写盘)。
    func updateTaskRecordMessageText(_ recordID: String?, messageID: String?, text: String) {
        guard let recordID, let messageID,
              let i = taskExecutionRecords.firstIndex(where: { $0.id == recordID }),
              let j = taskExecutionRecords[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        taskExecutionRecords[i].messages[j].text = LingShuTaskMessageFormatting.sanitize(text)
    }

    /// 跑一个 agent 并**流式**把进展更新进任务时间线的一条参与方气泡;收尾把最终输出落定。返回 agent 执行结果。
    func runAgentStreamingToRecord(_ plugin: LingShuAgentPlugin, objective: String, recordID rid: String,
                                   actor: String, role: String, startText: String)
        async -> LingShuAgentPluginStore.AgentRunResult {
        appendTaskRecordMessage(rid, actor: actor, role: role, kind: .agent, text: startText)
        let msgID = taskExecutionRecords.first(where: { $0.id == rid })?.messages.last?.id
        let startedAt = Date()
        let result = await LingShuAgentPluginStore.run(
            plugin, objective: objective, workingDirectory: agentWorkingDirectory,
            progress: { tail in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let secs = Int(Date().timeIntervalSince(startedAt))
                    self.updateTaskRecordMessageText(rid, messageID: msgID,
                        text: startText + "\n\n⏳ 运行中(\(secs)s):\n" + String(tail.suffix(700)))
                }
            })
        // 收尾:把这条流式气泡定格成最终结论尾部,并持久化一次。
        let finalText: String
        switch result {
        case .completed(let t): finalText = startText + "\n\n✓ 完成:\n" + String(t.suffix(900))
        case .failure(let f):   finalText = startText + "\n\n✗ 未完成:" + String(f.prefix(300))
        }
        updateTaskRecordMessageText(rid, messageID: msgID, text: finalText)
        persistTaskExecutionRecords()
        return result
    }
}
