import Foundation

@MainActor
extension LingShuState {
    /// 任务卡住等用户输入时，把原气泡变成可交互的续跑入口。
    func markDispatchedBubbleAwaitingInput(recordID: String, question: String) {
        let interaction = LingShuWorkflowControlEnvelope.extract(from: question)?.humanInteraction?.normalized
        let cleanQuestion = LingShuHumanInputEnvelope.userFacingText(from: question)
        let text = interaction.map { "⏸ 等待人机协作:\($0.prompt)" } ?? "⏸ 等待前提:\(cleanQuestion)"
        var choices = interaction?.choicePrompt
            ?? LingShuChoiceParsing.parse(question)
            ?? LingShuChoiceParsing.parse(cleanQuestion)
            ?? userPrerequisiteChoicePromptIfNeeded(resultText: cleanQuestion, taskRecordID: recordID)
        if choices == nil,
           let interaction,
           [.qrCode, .externalLogin, .physicalAction, .confirmation].contains(interaction.kind) {
            choices = .init(
                question: interaction.prompt,
                options: [
                    .init(label: "已完成，继续", detail: "我已经完成这一步，继续原任务。"),
                    .init(label: "先暂停", detail: "保留当前进度，稍后再继续。")
                ]
            )
        }
        let form = interaction.flatMap { request -> LingShuConfirmForm? in
            guard request.kind == .form, let json = request.payload["form_json"] else { return nil }
            return LingShuConfirmForm.parse(json)
        }
        if let bid = dispatchedTaskBubbles[recordID], let idx = chatMessages.firstIndex(where: { $0.id == bid }) {
            chatMessages[idx].text = text
            chatMessages[idx].isLoading = false
            chatMessages[idx].choices = choices
            chatMessages[idx].form = form
            chatMessages[idx].humanInteraction = interaction
            chatMessages[idx].awaitingInputForRecordID = recordID
        } else {
            chatMessages.append(.init(
                speaker: "灵枢",
                text: text,
                isUser: false,
                taskRecordID: recordID,
                choices: choices,
                form: form,
                awaitingInputForRecordID: recordID,
                humanInteraction: interaction
            ))
        }
        if let interaction {
            pendingDispatchedHumanInteractions[recordID] = interaction
            startHumanInteractionProbeIfNeeded(
                interaction,
                bubbleID: dispatchedTaskBubbles[recordID] ?? UUID(),
                recordID: recordID
            )
        }
        dispatchedTaskBubbles[recordID] = nil
    }

    /// 气泡内的回答直达原隔离会话，并按恢复令牌接回精确的工作流或验收节点。
    func answerDispatchedTask(recordID: String, answer: String, displayAnswer: String? = nil) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let interaction = pendingDispatchedHumanInteractions.removeValue(forKey: recordID)
        if let request = interaction {
            humanInteractionProbeTasks.removeValue(forKey: request.id)?.cancel()
        }
        let visibleAnswer = (displayAnswer ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = chatMessages.firstIndex(where: { $0.awaitingInputForRecordID == recordID }) {
            chatMessages[index].awaitingInputForRecordID = nil
            if chatMessages[index].resolvedChoice == nil {
                chatMessages[index].resolvedChoice = visibleAnswer
            }
        }
        chatMessages.append(.init(speaker: "你", text: visibleAnswer, isUser: true, taskRecordID: recordID))
        requestChatScrollToLatestForUserSend()
        appendTaskRecordMessage(recordID, actor: "你", role: "答复", kind: .user, text: visibleAnswer)
        if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }
        guard let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key else {
            _ = runMainAgentTurn(prompt: trimmed, taskRecordID: recordID, resumeBlocked: true)
            return
        }
        installAgentEventSinkIfNeeded()
        let wasWaiting = taskExecutionRecords.first { $0.id == recordID }?.taskOutcome == .waitingForUser
        let providesPrerequisite = Self.userInputProvidesPrerequisite(trimmed)
        if wasWaiting && providesPrerequisite { resolveUserProvidedGaps(recordID: recordID) }
        let resumeInput = wasWaiting && providesPrerequisite
            ? trimmed + "\n\n" + capabilityResumePreamble(recordID: recordID)
            : trimmed
        let pending = ChatMessage(
            speaker: "灵枢",
            text: dialogueAcknowledgement.intake(for: visibleAnswer),
            isUser: false,
            isLoading: true,
            taskRecordID: recordID
        )
        chatMessages.append(pending)
        dispatchedTaskBubbles[recordID] = pending.id
        appendTrace(kind: .route, actor: "任务气泡", title: "气泡内直答", detail: "气泡内回复直达派发任务隔离会话(不经分诊)。")
        let orchestrator = agentOrchestrator

        if let interaction, LingShuVerificationResumeToken.decode(interaction.resumeToken) != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.prepareSubtaskArtifactDelta(subID: subID, recordID: recordID)
                guard let outcome = await self.resumeVerificationInteraction(interaction, answer: trimmed) else {
                    await orchestrator.resumeWithInput(id: subID, input: resumeInput)
                    return
                }
                switch outcome {
                case .waiting(let next):
                    let envelope = LingShuWorkflowControlEnvelope(event: .requiresHumanInteraction(next))
                    self.markDispatchedBubbleAwaitingInput(recordID: recordID, question: envelope.encodedPrompt)
                case .ready(_, _, let makerResult):
                    await orchestrator.resumeAcceptance(id: subID, checkpointResult: makerResult)
                case .interrupted(let reason):
                    var retry = interaction
                    retry.prompt = "验收通道暂时中断。人工步骤结果已保留；通道恢复后点击继续即可从验收断点接上。\n\n\(LingShuModelServiceFailure.suspendedSummary(for: reason))"
                    let envelope = LingShuWorkflowControlEnvelope(event: .requiresHumanInteraction(retry))
                    self.markDispatchedBubbleAwaitingInput(recordID: recordID, question: envelope.encodedPrompt)
                }
            }
            return
        }
        if let interaction, LingShuWorkflowResumeToken.decode(interaction.resumeToken) != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.prepareSubtaskArtifactDelta(subID: subID, recordID: recordID)
                if let workflowOutput = await self.resumeWorkflowInteraction(interaction, recordID: recordID, answer: trimmed) {
                    if LingShuWorkflowControlEnvelope.extract(from: workflowOutput)?.humanInteraction != nil {
                        self.markDispatchedBubbleAwaitingInput(recordID: recordID, question: workflowOutput)
                    } else {
                        await orchestrator.resumeWithInput(
                            id: subID,
                            input: "【动态工作流续跑结果】\n\(workflowOutput)\n请基于真实结果继续原任务并完成交付。"
                        )
                    }
                } else {
                    await orchestrator.resumeWithInput(id: subID, input: resumeInput)
                }
            }
            return
        }
        Task { @MainActor [weak self] in
            await self?.prepareSubtaskArtifactDelta(subID: subID, recordID: recordID)
            await orchestrator.resumeWithInput(id: subID, input: resumeInput)
        }
    }
}
