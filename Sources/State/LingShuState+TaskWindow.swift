import Foundation

/// 子任务窗口(codex 式)的交互动作:窗口内追问续跑、文件改动撤销、点赞/点踩反馈。
/// 渲染在 LingShuTaskExecutionRecordViews / LingShuTaskWindowCards,数据走任务执行记录。
@MainActor
extension LingShuState {

    /// 窗口内追问:把追问当本任务记录的续跑——agent 循环以**同一条记录**继续(执行流追加进窗口,实时可见),
    /// 走持久主会话(带上下文)。同时进主对话气泡(与正常输入一致)。**支持附件**(与主输入框同一套 ingest 管线)。
    func submitTaskFollowup(_ text: String, recordID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentContext = attachmentContextBlock()
        guard (!trimmed.isEmpty || !attachmentContext.isEmpty), !hasActiveModelCall else { return }
        // 有附件时:窗口里显示用户原文,发给模型的提示前置附件正文(与主输入框 sendPrompt 同口径)。
        let combined: String
        if attachmentContext.isEmpty {
            combined = trimmed
        } else {
            combined = trimmed.isEmpty
                ? "\(attachmentContext)\n\n请按上述文件落地交付。"
                : "\(attachmentContext)\n\n用户指令：\n\(trimmed)"
        }
        let display = trimmed.isEmpty ? "[上传了 \(pendingAttachments.count) 个文件]" : trimmed
        appendTaskRecordMessage(recordID, actor: "你", role: "追问", kind: .user, text: display)
        captureDesignFeedbackForDreaming(trimmed, recordID: recordID)   // 设计任务的追问/改进→dreaming 固化
        clearAttachments()
        // 这条记录若属于**隔离子任务**(派发/spawn 出来的并行任务)→ 续跑**那条隔离会话本身**(它才有真上下文),
        // 而非主会话。否则主会话不知道这条任务做过什么,「继续」就接不上(尤其网络中断暂停后续跑)。
        if let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key {
            installAgentEventSinkIfNeeded()
            Task { await agentOrchestrator.resumeWithInput(id: subID, input: combined) }
            return
        }
        runMainAgentTurn(prompt: combined, taskRecordID: recordID)
    }

    /// **流程纠正(干预)**:看到 agent 跑偏时,中途把纠正注入**正在跑的会话**(主/自主)。
    /// agent 循环在回合边界(工具结果已补齐 / 模型刚出文本)采纳为最高优先级 user 指令,下一步即改方向——
    /// 比"停止后重发"更平滑:不丢已建立的上下文、不打断在飞工具产生半截状态。
    func interjectCorrection(_ text: String, recordID: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 纠正也支持附件:有附件就把附件正文并进纠正指令(随手丢个截图/文件纠偏)。
        let attachmentContext = attachmentContextBlock()
        guard !trimmed.isEmpty || !attachmentContext.isEmpty else { return }
        let correction = attachmentContext.isEmpty ? trimmed : "\(attachmentContext)\n\n纠正:\(trimmed)"
        let display = trimmed.isEmpty ? "[随纠正上传了 \(pendingAttachments.count) 个文件]" : trimmed
        appendTaskRecordMessage(recordID, actor: "你", role: "纠正", kind: .user, text: display)
        appendTrace(kind: .warning, actor: "干预", title: "用户中途纠正", detail: display)
        captureDesignFeedbackForDreaming(trimmed, recordID: recordID)   // 设计任务的纠正→dreaming 固化
        missionStatus = "收到纠正,正在调整方向…"
        clearAttachments()
        let main = mainAgentSessionHolder
        let autonomous = autonomousSessionHolder
        // 这条记录若属于**派发的隔离子任务**,纠正要注入**那条隔离会话本身**(它才是真正在跑的 maker)——
        // 主/自主会话的 interject 够不到编排器里的子会话(否则空转的派发任务没法从外部叫停/纠偏)。
        let subID = recordID.flatMap { rid in agentSubTaskRecords.first(where: { $0.value == rid })?.key }
        let orchestrator = agentOrchestrator
        Task {
            await main?.injectCorrection(correction)
            await autonomous?.injectCorrection(correction)
            if let subID { await orchestrator.injectCorrection(id: subID, correction) }
        }
    }

    /// 停止当前在飞回合(真停)——供任务窗口"停止"按钮。
    func stopActiveRun() { cancelCurrentCall() }

    /// 撤销一次文件改动:新增的删文件、修改的还原改前内容(从 diff 无损重建);截断 diff 不可撤销。
    func undoFileEdit(messageID: String, recordID: String) {
        guard let recordIndex = taskExecutionRecords.firstIndex(where: { $0.id == recordID }),
              let messageIndex = taskExecutionRecords[recordIndex].messages.firstIndex(where: { $0.id == messageID }),
              case let .fileEdit(path, operation, _, _, diff)? = taskExecutionRecords[recordIndex].messages[messageIndex].detail
        else { return }

        do {
            if operation == .created {
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            } else {
                guard let old = LingShuLineDiff.reconstructOld(fromUnified: diff) else {
                    appendTrace(kind: .warning, actor: "撤销", title: "无法撤销", detail: "改动过大(diff 已截断),不支持还原。")
                    return
                }
                try old.write(toFile: path, atomically: true, encoding: .utf8)
            }
            taskExecutionRecords[recordIndex].messages[messageIndex].undone = true
            persistTaskExecutionRecords()
            appendTrace(kind: .warning, actor: "撤销", title: "已撤销文件改动", detail: path)
        } catch {
            appendTrace(kind: .warning, actor: "撤销", title: "撤销失败", detail: error.localizedDescription)
        }
    }

    /// 设置/清除任务反馈(👍true / 👎false / nil 清除)。持久化;👎 会让该任务不进 dreaming 固化样本。
    func setTaskFeedback(_ value: Bool?, recordID: String) {
        if let value { taskRecordFeedback[recordID] = value } else { taskRecordFeedback.removeValue(forKey: recordID) }
        UserDefaults.standard.set(taskRecordFeedback, forKey: "lingshu.taskFeedback")
        appendTrace(kind: .system, actor: "反馈",
                    title: value == true ? "赞" : (value == false ? "踩" : "清除反馈"),
                    detail: "任务 \(recordID) 反馈已记录(踩的输出不进自固化样本)。")
    }

    /// 模型供应商选单(窗口内模型选择器用)。
    var taskWindowModelProviders: [String] {
        ModelProviderPreset.catalog.map(\.name)
    }
}
