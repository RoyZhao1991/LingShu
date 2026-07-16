import Foundation

struct LingShuPendingVerificationInteraction {
    var token: LingShuVerificationResumeToken
    var session: (any LingShuAgentSessioning)?
    var objective: String
    var makerResult: LingShuAgentRunResult
    /// The answer has already been appended to the checker history. If the model channel then
    /// fails, the next retry must continue the pending model call instead of appending it again.
    var humanAnswerDelivered = false
}

enum LingShuVerificationInteractionResumeOutcome {
    case waiting(LingShuHumanInteractionRequest)
    case ready(recordID: String?, objective: String, makerResult: LingShuAgentRunResult)
    case interrupted(String)
}

@MainActor
extension LingShuState {
    nonisolated static func verificationContinuationKey(
        recordID: String?,
        mode: LingShuVerificationResumeToken.Mode,
        scope: String
    ) -> String {
        "\(recordID ?? "__main__")|\(mode.rawValue)|\(scope)"
    }

    func consumeResumedVerificationVerdict(
        recordID: String?,
        mode: LingShuVerificationResumeToken.Mode,
        scope: String
    ) -> String? {
        resumedVerificationVerdicts.removeValue(
            forKey: Self.verificationContinuationKey(recordID: recordID, mode: mode, scope: scope)
        )
    }

    func consumeResumedVerificationHumanResult(
        recordID: String?,
        mode: LingShuVerificationResumeToken.Mode,
        scope: String
    ) -> String? {
        resumedVerificationHumanResults.removeValue(
            forKey: Self.verificationContinuationKey(recordID: recordID, mode: mode, scope: scope)
        )
    }

    /// Retain a verification checkpoint. Internal checker sessions are kept alive and resumed
    /// exactly; an external checker process cannot stay resident, so its node is replayed with
    /// the human result while the maker result and parent task remain unchanged.
    func retainVerificationInteraction(
        _ interaction: LingShuHumanInteractionRequest,
        mode: LingShuVerificationResumeToken.Mode,
        scope: String,
        recordID: String?,
        objective: String,
        makerResult: LingShuAgentRunResult,
        session: (any LingShuAgentSessioning)?
    ) -> LingShuHumanInteractionRequest {
        let token = LingShuVerificationResumeToken(
            id: UUID().uuidString,
            mode: mode,
            recordID: recordID,
            scope: scope
        )
        pendingVerificationInteractions[token.id] = .init(
            token: token,
            session: session,
            objective: objective,
            makerResult: makerResult
        )
        var request = interaction
        if let upstream = request.resumeToken, !upstream.isEmpty {
            request.payload["upstream_resume_token"] = upstream
        }
        request.resumeToken = token.encoded
        if request.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            request.source = "审查员"
        }
        return request.normalized ?? interaction
    }

    func resumeVerificationInteraction(
        _ request: LingShuHumanInteractionRequest,
        answer: String
    ) async -> LingShuVerificationInteractionResumeOutcome? {
        guard let token = LingShuVerificationResumeToken.decode(request.resumeToken),
              var pending = pendingVerificationInteractions[token.id] else { return nil }
        let key = Self.verificationContinuationKey(recordID: token.recordID, mode: token.mode, scope: token.scope)
        let resumeInput = "【人机协作已完成】\n类型：\(request.kind.rawValue)\n结果：\(answer)\n请从刚才的验收断点继续，只输出标准 checker verdict。"

        guard let session = pending.session else {
            // External CLI checkers are one-shot processes. Keep the same checker node and replay
            // only that node with the human result; never send the answer to the maker.
            resumedVerificationHumanResults[key] = answer
            pendingVerificationInteractions.removeValue(forKey: token.id)
            return .ready(recordID: token.recordID, objective: pending.objective, makerResult: pending.makerResult)
        }

        let result: LingShuAgentRunResult
        if pending.humanAnswerDelivered {
            result = await session.continueLoop()
        } else {
            pending.humanAnswerDelivered = true
            pendingVerificationInteractions[token.id] = pending
            result = await session.resume(resumeInput)
        }
        switch result {
        case .blocked(let question):
            var next = LingShuWorkflowControlEnvelope.extract(from: question)?.humanInteraction
                ?? .init(kind: .question, title: "验收需要你参与", prompt: LingShuHumanInputEnvelope.userFacingText(from: question))
            if let upstream = next.resumeToken, !upstream.isEmpty {
                next.payload["upstream_resume_token"] = upstream
            }
            next.resumeToken = token.encoded
            next.source = next.source ?? request.source ?? "审查员"
            pending.session = session
            pending.humanAnswerDelivered = false
            pendingVerificationInteractions[token.id] = pending
            return .waiting(next.normalized ?? next)
        case .interrupted(let reason):
            pending.session = session
            pendingVerificationInteractions[token.id] = pending
            return .interrupted(reason)
        case .completed(let text), .maxTurnsReached(let text):
            resumedVerificationVerdicts[key] = text
            pendingVerificationInteractions.removeValue(forKey: token.id)
            return .ready(recordID: token.recordID, objective: pending.objective, makerResult: pending.makerResult)
        }
    }

    func renderGenericHumanInteraction(
        _ request: LingShuHumanInteractionRequest,
        bubbleID: UUID,
        recordID: String?,
        context: LingShuPendingHumanInputContext,
        prompt: String,
        elapsed: TimeInterval
    ) -> Bool {
        guard let request = request.normalized else { return false }
        var choices = request.choicePrompt
        if choices == nil, [.qrCode, .externalLogin, .physicalAction, .confirmation].contains(request.kind) {
            choices = LingShuRouteChoicePrompt(
                question: request.prompt,
                options: [
                    .init(label: "已完成，继续", detail: "我已经完成这一步，继续原任务。"),
                    .init(label: "先暂停", detail: "保留当前进度，稍后再继续。")
                ]
            )
        }

        var form: LingShuConfirmForm?
        if request.kind == .form, let formJSON = request.payload["form_json"] {
            form = LingShuConfirmForm.parse(formJSON)
        }

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
        startHumanInteractionProbeIfNeeded(request, bubbleID: bubbleID, recordID: recordID)
        return true
    }

    func resolveMainHumanInteraction(messageID: UUID, answer: String, displayAnswer: String? = nil) {
        guard let pending = pendingHumanInteractionContexts.removeValue(forKey: messageID) else { return }
        pendingChoiceContexts.removeValue(forKey: messageID)
        pendingFormContexts.removeValue(forKey: messageID)
        humanInteractionProbeTasks.removeValue(forKey: pending.request.id)?.cancel()
        let visible = (displayAnswer ?? answer).trimmingCharacters(in: .whitespacesAndNewlines)
        let input = "【人机协作已完成】\n类型:\(pending.request.kind.rawValue)\n结果:\(answer)\n请从暂停点继续原任务，不要重新开始。"
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
