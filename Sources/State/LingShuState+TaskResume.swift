import Foundation

/// 任务续接二次确认的挂起上下文。
struct LingShuPendingTaskResume: Equatable {
    let prompt: String
    let source: LingShuDialogueInputSource
    let taskRecordID: String?
}

/// 任务回溯的语义匹配二次确认与候选挑选。
/// - 中置信：发"继续这个 / 这是新任务"选择卡，不赌错任务。
/// - 明确回溯但无精确命中：给 top3 语义近似 + "都不是，新任务开始"。
/// - 高置信 / 普通新任务：返回 nil，主流程照常推进。
@MainActor
extension LingShuState {
    func presentTaskResumeConfirmationIfNeeded(
        lookup: LingShuTaskMemoryLookup,
        prompt: String,
        source: LingShuDialogueInputSource,
        taskRecordID: String?
    ) -> String? {
        switch lookup.confidence {
        case .high:
            return nil

        case .medium:
            guard let primary = lookup.candidates.first else { return nil }
            return presentResumeCard(
                question: "我记得有个相近的任务，但不太确定是不是它。你是想继续这个，还是当成新任务？",
                candidates: Array(lookup.candidates.prefix(3)),
                primaryHint: primary,
                prompt: prompt,
                source: source,
                taskRecordID: taskRecordID
            )

        case .none:
            // 明确点名要回溯却没精确命中：给语义近似候选让用户挑。
            let resumable = lookup.candidates.filter { $0.taskID != nil }
            guard lookup.explicitResume, !resumable.isEmpty else { return nil }
            return presentResumeCard(
                question: "我没有精确匹配到你说的那个任务。下面几个比较接近，你要继续哪个？都不是的话我就开个新任务。",
                candidates: Array(resumable.prefix(3)),
                primaryHint: nil,
                prompt: prompt,
                source: source,
                taskRecordID: taskRecordID
            )
        }
    }

    private func presentResumeCard(
        question: String,
        candidates: [LingShuTaskResumeCandidate],
        primaryHint: LingShuTaskResumeCandidate?,
        prompt: String,
        source: LingShuDialogueInputSource,
        taskRecordID: String?
    ) -> String {
        pendingTaskResume = .init(prompt: prompt, source: source, taskRecordID: taskRecordID)

        var options: [CodexRouteChoiceOption] = candidates.compactMap { candidate in
            guard let taskID = candidate.taskID else { return nil }
            let detail = "\(candidate.summary.isEmpty ? "（无摘要）" : candidate.summary) · \(candidate.updatedAt.taskRecordDisplayTime) · \(candidate.matchedBy)"
            return .init(label: "继续：\(candidate.title)", detail: detail, action: "resume:\(taskID)")
        }
        // 至少要有一个可续接项，否则退回新任务（不发空卡）。
        guard !options.isEmpty else {
            pendingTaskResume = nil
            return ""
        }
        options.append(.init(label: "都不是，按新任务开始", detail: "忽略历史，新建一个独立任务上下文。", action: "new-task"))

        let promptPayload = CodexRouteChoicePrompt(question: question, options: options)
        appendTrace(kind: .route, actor: "记忆", title: "任务回溯待确认", detail: "语义匹配置信不足，已请用户在 \(options.count) 个选项中确认。")
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .router, text: question)

        let message = ChatMessage(
            speaker: "灵枢",
            text: question,
            isUser: false,
            taskRecordID: taskRecordID,
            choices: promptPayload.sanitized
        )
        chatMessages.append(message)
        return question
    }

    /// 选择卡上的结构化动作：resume:<taskID> 续接指定任务，new-task 开新任务。
    func performChoiceAction(_ action: String) {
        guard let pending = pendingTaskResume else {
            appendTrace(kind: .warning, actor: "记忆", title: "动作已失效", detail: "续接上下文已不存在，忽略本次选择。")
            return
        }
        pendingTaskResume = nil

        if action == "new-task" {
            appendTrace(kind: .route, actor: "记忆", title: "用户选择新任务", detail: "忽略历史候选，按新任务上下文推进。")
            _ = submitTextInput(
                pending.prompt,
                source: pending.source,
                existingTaskRecordID: pending.taskRecordID,
                appendUserMessage: false,
                forcedThreadID: "task-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
            )
            return
        }

        if action.hasPrefix("resume:") {
            let taskID = String(action.dropFirst("resume:".count))
            appendTrace(kind: .route, actor: "记忆", title: "用户确认续接", detail: "继续历史任务线程 \(taskID)，继承前序执行上下文。")
            _ = submitTextInput(
                pending.prompt,
                source: pending.source,
                existingTaskRecordID: pending.taskRecordID,
                appendUserMessage: false,
                forcedThreadID: taskID
            )
            return
        }

        appendTrace(kind: .warning, actor: "记忆", title: "未知动作", detail: "无法识别的选择动作：\(action)。")
    }
}
