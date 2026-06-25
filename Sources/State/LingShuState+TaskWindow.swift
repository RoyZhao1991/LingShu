import Foundation

/// 子任务窗口(codex 式)的交互动作:窗口内追问续跑、文件改动撤销、点赞/点踩反馈。
/// 渲染在 LingShuTaskExecutionRecordViews / LingShuTaskWindowCards,数据走任务执行记录。
@MainActor
extension LingShuState {

    /// 窗口内追问:把追问当本任务记录的续跑——以**同一条记录**继续(执行流追加进窗口,实时可见)。
    /// **线程隔离(2026-06-25):始终走这条记录自己的隔离会话,绝不落主会话**——有现存隔离子会话就续它(`resumeWithInput`),
    /// 没有(主线程直答记录/会话已结束)就为这条记录**重新派发一条隔离会话**续推进;主会话上下文不被污染。**支持附件**(同主输入框 ingest 管线)。
    func submitTaskFollowup(_ text: String, recordID: String, appendUserMessage: Bool = true) {
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
        let isWaitingForPrerequisite = taskExecutionRecords.first { $0.id == recordID }?.taskOutcome == .waitingForUser
        if isWaitingForPrerequisite && Self.userInputDeniesPrerequisite(combined) {
            clearAttachments()
            closeDispatchedTaskForDeniedPrerequisite(recordID: recordID, answer: display)
            return
        }
        if appendUserMessage {   // 干预 fallback 进来时,纠正已作为「纠正」贴过,不重复贴
            appendTaskRecordMessage(recordID, actor: "你", role: "追问", kind: .user, text: display)
        }
        captureDesignFeedbackForDreaming(trimmed, recordID: recordID)   // 设计任务的追问/改进→dreaming 固化
        clearAttachments()
        // 这条记录若属于**隔离子任务**(派发/spawn 出来的并行任务)→ 续跑**那条隔离会话本身**(它才有真上下文),
        // 而非主会话。否则主会话不知道这条任务做过什么,「继续」就接不上(尤其网络中断暂停后续跑)。
        if let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key {
            installAgentEventSinkIfNeeded()
            // P2 真闭环:用户在回应「能力缺口」卡住 →
            // ① **解除需用户提供的阻断缺口**(用户已给凭据/已指路)——否则静态 gapAnalysis 让完成闸**无限再问同一件事**
            //    (用户反馈"给了 token 仍没完成"的根因);解除后据本回合**真实结果**判完成,而非据陈旧缺口再问。
            // ② 给一段续接引导,逼它真用上/真去试可行路径,别只读文件就说做不了。
            let providesPrerequisite = Self.userInputProvidesPrerequisite(combined)
            if isWaitingForPrerequisite && providesPrerequisite { resolveUserProvidedGaps(recordID: recordID) }
            let resumeInput = isWaitingForPrerequisite && providesPrerequisite
                ? combined + "\n\n" + capabilityResumePreamble(recordID: recordID)
                : combined
            Task { await agentOrchestrator.resumeWithInput(id: subID, input: resumeInput) }
            return
        }
        // **线程隔离(用户定调 2026-06-25):任务窗口的追问绝不落主会话**——这条记录是一条**独立隔离线程**。
        // 没有现存隔离子会话(主线程直答记录 / 子会话已结束被丢)→ **为这条记录重新派发一条隔离会话**续推进
        // (带它此前的目标/进展作上下文),主会话上下文**不被污染**;子→主只经 `briefMainThread` 同步蒸馏简报(完成/落文件时)。
        // 重新派发后会建出本记录的新隔离子会话,之后的追问就走上面 subID 分支续同一条会话(连续推进)。
        let providesPrerequisite = Self.userInputProvidesPrerequisite(combined)
        if isWaitingForPrerequisite && providesPrerequisite { resolveUserProvidedGaps(recordID: recordID) }
        let resumeInput = isWaitingForPrerequisite && providesPrerequisite
            ? combined + "\n\n" + capabilityResumePreamble(recordID: recordID)
            : combined
        let record = taskExecutionRecords.first { $0.id == recordID }
        let priorBrief = [record?.goal, record?.summary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let isolatedInput = priorBrief.isEmpty
            ? resumeInput
            : "【接续这条隔离任务(它此前:\(String(priorBrief.prefix(200))))】\n\n\(resumeInput)"
        _ = dispatchIsolatedTask(prompt: isolatedInput, taskRecordID: recordID, goal: record?.goal)
    }

    /// **子线程统一交互入口(对齐 codex 的子线程:一条独立隔离线程,发消息就续跑、始终有执行+回复)。**
    /// 窗口 footer 只调这一个——不再按不可靠的「执行中」标志分「纠正/追问」两套(那是「子线程收到没回复」的根因):
    /// ① 这条记录的隔离子会话/主会话循环**正在飞** → 注入 steer(循环在回合边界采纳、续跑产出执行+回复);
    /// ② **没在飞**(循环已结束,如演示交给播放循环、回合已收尾)→ 重新起/续隔离会话 re-engage(产出执行+回复)。
    /// 两条路都落进这条记录的窗口、都不污染主会话、都不破坏线程隔离。
    func continueTaskThread(_ text: String, recordID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentContext = attachmentContextBlock()
        guard !trimmed.isEmpty || !attachmentContext.isEmpty else { return }
        let combined: String
        if attachmentContext.isEmpty {
            combined = trimmed
        } else {
            combined = trimmed.isEmpty
                ? "\(attachmentContext)\n\n请按上述文件落地交付。"
                : "\(attachmentContext)\n\n用户指令：\n\(trimmed)"
        }
        let display = trimmed.isEmpty ? "[上传了 \(pendingAttachments.count) 个文件]" : trimmed
        appendTaskRecordMessage(recordID, actor: "你", role: "续", kind: .user, text: display)
        captureDesignFeedbackForDreaming(trimmed, recordID: recordID)
        clearAttachments()
        let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key
        let main = mainAgentSessionHolder
        let isMainTaskRunning = (currentAgentTurnRecordID == recordID)
        let orchestrator = agentOrchestrator
        Task { @MainActor [weak self] in
            guard let self else { return }
            var landed = false
            // ① 在飞的隔离子会话 → steer(注入,loop 续跑采纳)。
            if let subID, await orchestrator.injectCorrection(id: subID, combined) { landed = true }
            // ① 这条记录正是主会话当前在跑的回合 → 注入主会话 steer。
            if !landed, isMainTaskRunning, let main, await main.injectCorrection(combined) { landed = true }
            // ② 没在飞 → 重新起/续隔离会话 re-engage(产出执行+回复);复位 batchInterrupt 防泄漏。
            if !landed {
                self.batchInterruptRequested = false
                self.submitTaskFollowup(combined, recordID: recordID, appendUserMessage: false)
            }
        }
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
        batchInterruptRequested = true   // 若正在 run_steps 批量执行,让它在下一步边界停下交还大脑采纳纠正
        clearAttachments()
        let main = mainAgentSessionHolder
        let autonomous = autonomousSessionHolder
        // 这条记录若属于**派发的隔离子任务**,纠正要注入**那条隔离会话本身**(它才是真正在跑的 maker)——
        // 主/自主会话的 interject 够不到编排器里的子会话(否则空转的派发任务没法从外部叫停/纠偏)。
        let subID = recordID.flatMap { rid in agentSubTaskRecords.first(where: { $0.value == rid })?.key }
        let orchestrator = agentOrchestrator
        Task { @MainActor [weak self] in
            // injectCorrection 返回**是否被一个正在跑的循环接住**(false=当前没在跑,只存了 pendingCorrection 没人消费)。
            var landed = false
            if let main, await main.injectCorrection(correction) { landed = true }
            if let autonomous, await autonomous.injectCorrection(correction) { landed = true }
            if let subID, await orchestrator.injectCorrection(id: subID, correction) { landed = true }
            guard let self else { return }
            // **修(2026-06-25,用户「子线程收到没回复」):**任务显示「执行中」但 agent 循环其实已结束
            // (如演示交给播放循环、回合已收尾)→ 注入没人接住、纠正石沉大海、零回复。这里兜底:
            // 没接住就当作对这条任务的**新指令**,重新起隔离会话续跑(产出执行过程+回复,对齐 codex/claude「收到消息就有执行+回复」),
            // 并复位 batchInterrupt(本就没有在跑的批量要打断,防它泄漏卡住后续验收)。
            if !landed {
                self.batchInterruptRequested = false
                if let recordID {
                    self.submitTaskFollowup(correction, recordID: recordID, appendUserMessage: false)
                } else {
                    self.missionStatus = "收到纠正,但当前没有在跑的任务可纠;请把它作为新指令发我。"
                }
            }
        }
    }

    /// 停止当前在飞回合(真停)——供任务窗口"停止"按钮。
    func stopActiveRun() { cancelCurrentCall() }

    /// 任务窗口里的记录是否还可被用户停止。
    /// 子任务窗口看到的是 record,不一定等同于主线程 `hasActiveModelCall`,所以这里按记录状态 + 编排器映射判断。
    func canStopTaskWindowRecord(_ recordID: String) -> Bool {
        guard let record = taskExecutionRecords.first(where: { $0.id == recordID }) else {
            return agentSubTaskRecords.values.contains(recordID) || dispatchedTaskBubbles[recordID] != nil
        }
        guard !record.status.isTerminal else { return false }
        let stoppable: Set<LingShuTaskExecutionStatus> = [
            .queued, .running, .dispatched, .analyzing, .acquiringCapability,
            .ready, .waitingForUser, .blocked, .suspended
        ]
        return stoppable.contains(record.status)
            || agentSubTaskRecords.values.contains(recordID)
            || dispatchedTaskBubbles[recordID] != nil
    }

    /// 停止任务窗口当前记录。
    /// - 派发/子任务:只取消对应隔离子会话,释放队列槽位,不误伤主问答线。
    /// - 主线程记录:走原有全局停止。
    /// - 已卡住/待用户但不在编排器内的记录:直接收口成失败,避免窗口和队列长期悬挂。
    func stopTaskWindowRecord(_ recordID: String) {
        guard canStopTaskWindowRecord(recordID) else { return }
        if agentSubTaskRecords.values.contains(recordID) || dispatchedTaskBubbles[recordID] != nil {
            stopDispatchedTask(recordID: recordID)
            return
        }
        if currentAgentTurnRecordID == recordID || autonomousRunRecordID == recordID {
            stopActiveRun()
            return
        }
        appendTaskRecordMessage(recordID, actor: "用户", role: "停止", kind: .warning, text: "用户已停止该任务。")
        if blockedDispatchedRecordID == recordID { blockedDispatchedRecordID = nil }
        finishTaskRecord(recordID, status: .failed, summary: "用户已停止该任务。")
        promoteQueuedDispatchIfPossible()
    }

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
    /// 子线程/任务窗口可切换的大脑:只列**已配置且校验通过**的文本通道(外加当前在用的),
    /// 不再平铺全量目录——没真接上/没校验通过的模型不让切换(用户要求 2026-06-16)。
    var taskWindowModelProviders: [String] {
        switchableTextProviders().map(\.name)
    }
}
