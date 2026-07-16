import Foundation

/// 结构化 human-in-the-loop 收口：agent 循环已经 `.blocked` 并释放任务槽；
/// 这里仅把加载气泡改造成可交互卡片，用户提交后再 resume 原工具调用。
@MainActor
extension LingShuState {

    @discardableResult
    func renderHumanInputBlockIfNeeded(result: LingShuAgentRunResult, bubbleID: UUID, recordID: String?, prompt: String, startedAt: Date) -> Bool {
        guard case .blocked(let raw) = result else { return false }
        let elapsed = Date().timeIntervalSince(startedAt)
        let context = LingShuPendingHumanInputContext(recordID: recordID, originalPrompt: prompt)

        if let control = LingShuWorkflowControlEnvelope.decode(from: raw),
           let interaction = control.humanInteraction {
            return renderGenericHumanInteraction(
                interaction,
                bubbleID: bubbleID,
                recordID: recordID,
                context: context,
                prompt: prompt,
                elapsed: elapsed
            )
        }

        guard let envelope = LingShuHumanInputEnvelope.decode(from: raw) else { return false }

        switch envelope.tool {
        case "ask_form":
            return renderFormBlock(envelope.argumentsJSON, bubbleID: bubbleID, recordID: recordID, context: context, prompt: prompt, elapsed: elapsed)
        case "ask_choice":
            return renderChoiceBlock(envelope.argumentsJSON, bubbleID: bubbleID, recordID: recordID, context: context, prompt: prompt, elapsed: elapsed)
        case "ask_user":
            return renderUserQuestionBlock(envelope.argumentsJSON, bubbleID: bubbleID, recordID: recordID, context: context, prompt: prompt, elapsed: elapsed)
        default:
            return false
        }
    }

    private func renderUserQuestionBlock(_ argsJSON: String, bubbleID: UUID, recordID: String?, context: LingShuPendingHumanInputContext, prompt: String, elapsed: TimeInterval) -> Bool {
        let question = Self.userQuestion(from: argsJSON)
        let cleanQuestion = LingShuHumanInputEnvelope.userFacingText(
            for: .init(tool: "ask_user", argumentsJSON: argsJSON)
        )
        let displayQuestion = question.isEmpty ? cleanQuestion : question
        let choices = LingShuChoiceParsing.parse(displayQuestion)
            ?? userPrerequisiteChoicePromptIfNeeded(resultText: displayQuestion, taskRecordID: recordID)
        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            chatMessages[index].text = "\(displayQuestion)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            chatMessages[index].choices = choices
            chatMessages[index].form = nil
            chatMessages[index].thinkingPreview = nil
        }
        if choices != nil { pendingChoiceContexts[bubbleID] = context }
        pendingMainQuestionRecordID = recordID
        let summary = "等待用户补充: \(displayQuestion)"
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "待用户", kind: .warning, text: summary)
        appendTrace(kind: .warning, actor: "Agent循环", title: choices == nil ? "等待用户" : "等待授权/选择", detail: String(displayQuestion.prefix(80)))
        finishTaskRecord(recordID, status: .waitingForUser, summary: summary)
        rememberMainThreadTurn(prompt: prompt, reply: summary)
        return true
    }

    private func renderFormBlock(_ argsJSON: String, bubbleID: UUID, recordID: String?, context: LingShuPendingHumanInputContext, prompt: String, elapsed: TimeInterval) -> Bool {
        guard let form = LingShuConfirmForm.parse(argsJSON) else { return false }
        if LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction(prompt) {
            autoResolveKnownSelfIntroductionForm(bubbleID: bubbleID, recordID: recordID, prompt: prompt, elapsed: elapsed)
            return true
        }
        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            chatMessages[index].text = "\(form.title)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            chatMessages[index].form = form
            chatMessages[index].choices = nil
            chatMessages[index].thinkingPreview = nil
        }
        pendingFormContexts[bubbleID] = context
        pendingMainQuestionRecordID = recordID
        let summary = "等待用户提交确认表单: \(form.title)"
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "待用户", kind: .warning, text: summary)
        appendTrace(kind: .warning, actor: "Agent循环", title: "等待表单", detail: String(form.title.prefix(80)))
        finishTaskRecord(recordID, status: .waitingForUser, summary: summary)
        rememberMainThreadTurn(prompt: prompt, reply: summary)
        return true
    }

    private func autoResolveKnownSelfIntroductionForm(bubbleID: UUID, recordID: String?, prompt: String, elapsed: TimeInterval) {
        let autoAnswer = "当前请求的主体是灵枢本人,信息已足够;不要再询问课题、受众或时长,请直接完成自我介绍。"
        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            chatMessages[index].text = "我知道了，这个不需要你再补表单。我直接介绍灵枢。\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            chatMessages[index].form = nil
            chatMessages[index].choices = nil
            chatMessages[index].thinkingPreview = nil
        }
        pendingMainQuestionRecordID = nil
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "自动确认", kind: .core, text: autoAnswer)
        appendTrace(kind: .route, actor: "Agent循环", title: "表单已抑制", detail: "自我介绍主体明确,自动回填确认并继续。")
        Task { @MainActor [weak self] in
            await Task.yield()
            _ = self?.runMainAgentTurn(
                prompt: autoAnswer,
                taskRecordID: recordID,
                resumeBlocked: true,
                originalPromptForVerification: prompt
            )
        }
    }

    private func renderChoiceBlock(_ argsJSON: String, bubbleID: UUID, recordID: String?, context: LingShuPendingHumanInputContext, prompt: String, elapsed: TimeInterval) -> Bool {
        let parsed = Self.parseChoiceArgs(argsJSON)
        let promptCard = LingShuRouteChoicePrompt(
            question: parsed.0.isEmpty ? "请选择下一步" : parsed.0,
            options: parsed.1.map { LingShuRouteChoiceOption(label: $0.label, detail: $0.detail) }
        )
        guard let sanitized = promptCard.sanitized else { return false }
        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            chatMessages[index].text = "\(sanitized.question)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            chatMessages[index].choices = sanitized
            chatMessages[index].form = nil
            chatMessages[index].thinkingPreview = nil
        }
        pendingChoiceContexts[bubbleID] = context
        pendingMainQuestionRecordID = recordID
        let summary = "等待用户选择: \(sanitized.question)"
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "待用户", kind: .warning, text: summary)
        appendTrace(kind: .warning, actor: "Agent循环", title: "等待选择", detail: String(sanitized.question.prefix(80)))
        finishTaskRecord(recordID, status: .waitingForUser, summary: summary)
        rememberMainThreadTurn(prompt: prompt, reply: summary)
        return true
    }

    nonisolated static func userQuestion(from argsJSON: String) -> String {
        guard let data = argsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return ((obj["question"] as? String)
                ?? (obj["prompt"] as? String)
                ?? (obj["message"] as? String)
                ?? (obj["title"] as? String)
                ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
