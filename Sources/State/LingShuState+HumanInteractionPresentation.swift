import Foundation

/// Presentation, queuing, and continuation of app-native human interaction.
@MainActor
extension LingShuState {
    func presentHardHumanInteraction(
        _ request: LingShuHumanInteractionRequest,
        target: LingShuPendingHardHumanInteraction.Target
    ) {
        guard Self.requiresHardHumanInteractionPresentation(request) else { return }
        let pending = LingShuPendingHardHumanInteraction(request: request, target: target)
        guard pendingHardHumanInteraction?.id != pending.id,
              !queuedHardHumanInteractions.contains(where: { $0.id == pending.id }) else { return }
        if pendingHardHumanInteraction == nil {
            pendingHardHumanInteraction = pending
        } else {
            queuedHardHumanInteractions.append(pending)
        }
    }

    /// Reopen a deferred hard interaction from its durable inline card.
    func presentHardHumanInteraction(_ request: LingShuHumanInteractionRequest) {
        if let entry = pendingHumanInteractionContexts.first(where: { $0.value.request.id == request.id }) {
            presentHardHumanInteraction(request, target: .main(messageID: entry.key))
            return
        }
        if let entry = pendingDispatchedHumanInteractions.first(where: { $0.value.id == request.id }) {
            presentHardHumanInteraction(request, target: .dispatched(recordID: entry.key))
        }
    }

    func isHumanInteractionPending(_ request: LingShuHumanInteractionRequest) -> Bool {
        pendingHumanInteractionContexts.values.contains(where: { $0.request.id == request.id })
            || pendingDispatchedHumanInteractions.values.contains(where: { $0.id == request.id })
    }

    /// "Handle later" only closes the modal. The task remains paused and the inline
    /// card remains available, while the next queued human step may be presented.
    func deferHardHumanInteraction() {
        pendingHardHumanInteraction = nil
        promoteNextHardHumanInteraction()
    }

    func completeHardHumanInteraction(
        _ pending: LingShuPendingHardHumanInteraction,
        answer: String,
        displayAnswer: String? = nil
    ) {
        clearHardHumanInteraction(requestID: pending.request.id)
        switch pending.target {
        case .main(let messageID):
            resolveMainHumanInteraction(messageID: messageID, answer: answer, displayAnswer: displayAnswer)
        case .dispatched(let recordID):
            answerDispatchedTask(recordID: recordID, answer: answer, displayAnswer: displayAnswer)
        }
    }

    func retryHardHumanInteractionMaterial(_ pending: LingShuPendingHardHumanInteraction) {
        let correction = """
        \(Self.interactionMaterialRetryMarker)
        The requested human interaction is not complete. The LingShu app did not receive the real user-visible material required to perform it. Retrieve or regenerate that material, then call request_human_interaction again with typed materials or source_job_id/source_log_path. Never direct the user to a terminal.
        """
        completeHardHumanInteraction(
            pending,
            answer: correction,
            displayAnswer: loc("正在重新获取交互内容", "Retrieving interaction content")
        )
    }

    func clearHardHumanInteraction(requestID: String) {
        queuedHardHumanInteractions.removeAll { $0.request.id == requestID }
        if pendingHardHumanInteraction?.request.id == requestID {
            pendingHardHumanInteraction = nil
            promoteNextHardHumanInteraction()
        }
    }

    private func promoteNextHardHumanInteraction() {
        while pendingHardHumanInteraction == nil, !queuedHardHumanInteractions.isEmpty {
            let next = queuedHardHumanInteractions.removeFirst()
            guard isHumanInteractionPending(next.request) else { continue }
            pendingHardHumanInteraction = next
        }
    }

    func renderGenericHumanInteraction(
        _ rawRequest: LingShuHumanInteractionRequest,
        bubbleID: UUID,
        recordID: String?,
        context: LingShuPendingHumanInputContext,
        prompt: String,
        elapsed: TimeInterval
    ) -> Bool {
        guard let normalized = rawRequest.normalized else { return false }
        let request = prepareHumanInteractionRequest(normalized)
        let isHard = Self.requiresHardHumanInteractionPresentation(request)
        let choices = isHard ? nil : request.choicePrompt
        let form = isHard ? nil : request.confirmForm

        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            chatMessages[index].text = "\(request.prompt)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            chatMessages[index].choices = choices
            chatMessages[index].form = form
            chatMessages[index].humanInteraction = request
            chatMessages[index].resolvedChoice = nil
            chatMessages[index].formAnswers = nil
            chatMessages[index].thinkingPreview = nil
        }

        pendingHumanInteractionContexts[bubbleID] = .init(request: request, inputContext: context)
        if choices != nil { pendingChoiceContexts[bubbleID] = context }
        if form != nil { pendingFormContexts[bubbleID] = context }
        pendingMainQuestionRecordID = recordID
        let summary = "等待人机协作: \(request.prompt)"
        appendTaskRecordMessage(recordID, actor: request.source ?? "灵枢", role: "等待人机协作", kind: .warning, text: summary)
        appendTrace(kind: .warning, actor: request.source ?? "运行时", title: "等待人机协作", detail: "\(request.kind.rawValue):\(String(request.prompt.prefix(100)))")
        finishTaskRecord(recordID, status: .waitingForUser, summary: summary)
        rememberMainThreadTurn(prompt: prompt, reply: summary)
        presentHardHumanInteraction(request, target: .main(messageID: bubbleID))
        startHumanInteractionProbeIfNeeded(request, bubbleID: bubbleID, recordID: recordID)
        return true
    }

    func resolveMainHumanInteraction(messageID: UUID, answer: String, displayAnswer: String? = nil) {
        guard let pending = pendingHumanInteractionContexts.removeValue(forKey: messageID) else { return }
        pendingChoiceContexts.removeValue(forKey: messageID)
        pendingFormContexts.removeValue(forKey: messageID)
        humanInteractionProbeTasks.removeValue(forKey: pending.request.id)?.cancel()
        clearHardHumanInteraction(requestID: pending.request.id)
        let visible = (displayAnswer ?? answer).trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].humanInteraction = nil
            chatMessages[index].choices = nil
            chatMessages[index].form = nil
            chatMessages[index].resolvedChoice = visible
            chatMessages[index].formAnswers = nil
        }
        let prerequisiteOption = selectedPrerequisiteOption(for: pending.request, answer: answer)
        let wasWaiting = pending.inputContext.recordID.flatMap { recordID in
            taskExecutionRecords.first { $0.id == recordID }?.taskOutcome
        } == .waitingForUser
        if let prerequisiteOption,
           Self.prerequisiteChoiceSemantics(prerequisiteOption) == .denyOrStop,
           wasWaiting,
           let recordID = pending.inputContext.recordID {
            pendingMainQuestionRecordID = nil
            if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                chatMessages[index].resolvedChoice = visible
            }
            closeDispatchedTaskForDeniedPrerequisite(recordID: recordID, answer: visible)
            return
        }
        let semanticAnswer: String
        if let prerequisiteOption,
           Self.prerequisiteChoiceSemantics(prerequisiteOption) == .alternative {
            semanticAnswer = Self.framedAlternativePrerequisiteInput(answer)
        } else {
            semanticAnswer = answer
        }
        if prerequisiteOption != nil,
           wasWaiting,
           Self.userInputProvidesPrerequisite(semanticAnswer) {
            resolveUserProvidedGaps(recordID: pending.inputContext.recordID)
        }
        let isMaterialRetry = answer.hasPrefix(Self.interactionMaterialRetryMarker)
        var input = isMaterialRetry
            ? answer
            : "【人机协作已完成】\n类型:\(pending.request.kind.rawValue)\n结果:\(semanticAnswer)\n请从暂停点继续原任务，不要重新开始。"
        if prerequisiteOption != nil,
           wasWaiting,
           Self.userInputProvidesPrerequisite(semanticAnswer) {
            input += "\n\n" + capabilityResumePreamble(recordID: pending.inputContext.recordID)
        }
        pendingMainQuestionRecordID = nil
        appendTaskRecordMessage(pending.inputContext.recordID, actor: "你", role: "人机协作结果", kind: .user, text: visible)
        if LingShuVerificationResumeToken.decode(pending.request.resumeToken) != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch await self.resumeVerificationInteraction(pending.request, answer: answer) {
                case .waiting(let next):
                    _ = self.renderGenericHumanInteraction(
                        next,
                        bubbleID: messageID,
                        recordID: pending.inputContext.recordID,
                        context: pending.inputContext,
                        prompt: pending.inputContext.originalPrompt,
                        elapsed: 0
                    )
                case .ready(let recordID, let objective, let makerResult):
                    _ = self.runMainAgentTurn(
                        prompt: objective,
                        taskRecordID: recordID ?? pending.inputContext.recordID,
                        originalPromptForVerification: pending.inputContext.originalPrompt,
                        existingBubbleID: messageID,
                        acceptanceCheckpoint: makerResult
                    )
                case .interrupted(let reason):
                    var retry = pending.request
                    retry.prompt = "验收通道暂时中断。人工步骤结果已保留；通道恢复后点击继续即可从验收断点接上。\n\n\(LingShuModelServiceFailure.suspendedSummary(for: reason))"
                    _ = self.renderGenericHumanInteraction(
                        retry,
                        bubbleID: messageID,
                        recordID: pending.inputContext.recordID,
                        context: pending.inputContext,
                        prompt: pending.inputContext.originalPrompt,
                        elapsed: 0
                    )
                case nil:
                    _ = self.runMainAgentTurn(
                        prompt: input,
                        taskRecordID: pending.inputContext.recordID,
                        resumeBlocked: true,
                        originalPromptForVerification: pending.inputContext.originalPrompt,
                        existingBubbleID: messageID
                    )
                }
            }
            return
        }
        if LingShuWorkflowResumeToken.decode(pending.request.resumeToken) != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let workflowOutput = await self.resumeWorkflowInteraction(
                    pending.request,
                    recordID: pending.inputContext.recordID,
                    answer: answer
                ) {
                    if let next = LingShuWorkflowControlEnvelope.extract(from: workflowOutput)?.humanInteraction {
                        _ = self.renderGenericHumanInteraction(
                            next,
                            bubbleID: messageID,
                            recordID: pending.inputContext.recordID,
                            context: pending.inputContext,
                            prompt: pending.inputContext.originalPrompt,
                            elapsed: 0
                        )
                        return
                    }
                    _ = self.runMainAgentTurn(
                        prompt: "【动态工作流续跑结果】\n\(workflowOutput)\n请基于真实结果继续原任务并完成最终回复。",
                        taskRecordID: pending.inputContext.recordID,
                        resumeBlocked: true,
                        originalPromptForVerification: pending.inputContext.originalPrompt
                    )
                    return
                }
                _ = self.runMainAgentTurn(
                    prompt: input,
                    taskRecordID: pending.inputContext.recordID,
                    resumeBlocked: true,
                    originalPromptForVerification: pending.inputContext.originalPrompt
                )
            }
            return
        }
        _ = runMainAgentTurn(
            prompt: input,
            taskRecordID: pending.inputContext.recordID,
            resumeBlocked: true,
            originalPromptForVerification: pending.inputContext.originalPrompt
        )
    }

    func selectedPrerequisiteOption(
        for request: LingShuHumanInteractionRequest,
        answer: String
    ) -> LingShuRouteChoiceOption? {
        guard request.payload["semantic_context"] == "prerequisite_choice" else { return nil }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let option = request.options.first(where: {
            $0.value == trimmed || $0.label == trimmed || $0.id == trimmed
        }) else { return nil }
        return .init(label: option.label, detail: option.detail.isEmpty ? nil : option.detail)
    }

    func consumePendingMainHumanInteraction(recordID: String, answer: String) -> Bool {
        guard let entry = pendingHumanInteractionContexts.first(where: { $0.value.inputContext.recordID == recordID }) else {
            return false
        }
        resolveMainHumanInteraction(messageID: entry.key, answer: answer)
        return true
    }

    func startHumanInteractionProbeIfNeeded(_ request: LingShuHumanInteractionRequest, bubbleID: UUID, recordID: String?) {
        guard let probe = request.completionProbe, probe.kind != .manual else { return }
        humanInteractionProbeTasks[request.id]?.cancel()
        humanInteractionProbeTasks[request.id] = Task { @MainActor [weak self] in
            let satisfied = await LingShuHumanInteractionProbe.waitUntilSatisfied(probe)
            guard let self, satisfied, !Task.isCancelled else { return }
            self.appendTrace(kind: .result, actor: "人机协作探针", title: "检测到已完成", detail: String(request.prompt.prefix(100)))
            if self.pendingHumanInteractionContexts[bubbleID] != nil {
                self.resolveMainHumanInteraction(messageID: bubbleID, answer: "完成探针已通过", displayAnswer: "已自动检测到操作完成")
            } else if let recordID, self.pendingDispatchedHumanInteractions[recordID] != nil {
                self.answerDispatchedTask(recordID: recordID, answer: "完成探针已通过", displayAnswer: "已自动检测到操作完成")
            }
        }
    }
}
