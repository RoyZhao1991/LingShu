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

}
