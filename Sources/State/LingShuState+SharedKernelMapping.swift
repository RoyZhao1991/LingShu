import Foundation

@MainActor
extension LingShuState {
    nonisolated static func sharedKernelProviderID(_ provider: String) -> String {
        let normalized = provider.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    nonisolated static func sharedKernelDate(_ raw: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw) ?? Date()
    }

    nonisolated static func sharedKernelGoalSpec(_ goal: LingShuKernelGoalSpec) -> LingShuGoalSpec {
        LingShuGoalSpec(
            objective: goal.objective,
            kind: LingShuGoalKind(rawValue: goal.kind.rawValue) ?? .unknown,
            constraints: goal.constraints,
            boundaries: goal.boundaries,
            risks: goal.risks,
            successCriteria: goal.successCriteria,
            openQuestions: goal.openQuestions,
            outputMode: LingShuOutputMode(rawValue: goal.outputMode.rawValue) ?? .unspecified,
            referenceScope: LingShuGoalReferenceScope(rawValue: goal.referenceScope.rawValue) ?? .unknown,
            referenceEvidence: goal.referenceEvidence,
            referenceExplicit: goal.referenceExplicit,
            referenceConfidence: LingShuGoalReferenceConfidence(rawValue: goal.referenceConfidence.rawValue) ?? .unknown
        )
    }

    nonisolated static func sharedKernelTaskStatus(
        _ status: LingShuKernelTaskStatus,
        goal: LingShuKernelGoalSpec?,
        hasArtifacts: Bool
    ) -> LingShuTaskExecutionStatus {
        switch status {
        case .queued: .queued
        case .understanding: .analyzing
        case .running: .running
        case .needsRecovery: .suspended
        case .needsUserAction: .waitingForUser
        case .completed:
            goal?.outputMode == .chatReply && !hasArtifacts ? .answered : .completed
        // Legacy persisted value only. A runtime interruption keeps the goal recoverable.
        case .failed: .suspended
        // Runtime cancellation is sealed. Keep it neutral, but never project it as a resumable
        // suspension: doing so can re-dispatch a task that the user explicitly terminated.
        case .cancelled: .terminated
        }
    }

    nonisolated static func sharedKernelPlanStatus(_ status: LingShuKernelTaskStatus) -> LingShuPlanStep.Status {
        switch status {
        case .queued, .needsUserAction, .failed: .pending
        case .understanding, .running, .needsRecovery: .inProgress
        case .completed: .completed
        case .cancelled: .cancelled
        }
    }

    nonisolated static func sharedKernelRoleStatus(_ status: LingShuKernelTaskStatus) -> LingShuTaskRoleSlotStatus {
        switch status {
        case .queued, .needsUserAction, .failed: .pending
        case .understanding, .running, .needsRecovery: .running
        case .completed: .completed
        case .cancelled: .cancelled
        }
    }

    nonisolated static func sharedKernelMessageKind(_ kind: LingShuKernelEventKind) -> LingShuTaskExecutionMessageKind {
        return switch kind {
        case .status: .core
        case .model, .reasoning: .model
        case .tool: .agent
        case .plan: .router
        case .delegation: .agent
        case .humanInteraction: .user
        case .warning: .warning
        case .result: .result
        }
    }

    nonisolated static func sharedKernelEventRole(
        _ kind: LingShuKernelEventKind,
        language: LingShuVoiceLanguage
    ) -> String {
        let english = language == .english
        return switch kind {
        case .status: english ? "Status" : "状态"
        case .model: english ? "Model" : "模型"
        case .reasoning: english ? "Reasoning" : "推理"
        case .tool: english ? "Tool" : "工具"
        case .plan: english ? "Plan" : "计划"
        case .delegation: english ? "Delegation" : "派发"
        case .humanInteraction: english ? "Human" : "人机协作"
        case .warning: english ? "Warning" : "警告"
        case .result: english ? "Result" : "结果"
        }
    }

    nonisolated static func sharedKernelStatusText(
        _ status: LingShuKernelTaskStatus,
        language: LingShuVoiceLanguage
    ) -> String {
        let english = language == .english
        return switch status {
        case .queued: english ? "Queued" : "排队中"
        case .understanding: english ? "Understanding" : "理解中"
        case .running: english ? "Running" : "执行中"
        case .needsRecovery: english ? "Recovering" : "自动恢复中"
        case .needsUserAction: english ? "Waiting for user" : "等待用户"
        case .completed: english ? "Completed" : "已完成"
        case .failed: english ? "Waiting to resume" : "待恢复"
        case .cancelled: english ? "Terminated" : "已终止"
        }
    }

    /// Main chat receives only a concise, user-facing progress sentence. Event detail is the
    /// diagnostic payload and remains available in the task execution record.
    nonisolated static func sharedKernelUserFacingEventText(
        _ event: LingShuKernelRuntimeEvent,
        language: LingShuVoiceLanguage
    ) -> String? {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)

        switch event.kind {
        case .tool, .plan, .delegation:
            return sharedKernelNonEmpty(title)
        case .reasoning:
            return language == .english ? "Thinking…" : "思考中…"
        case .model:
            if let detail = sharedKernelReadableEventDetail(event.detail) {
                return detail
            }
            if title.hasPrefix("模型回合 ") || title.hasPrefix("Model turn ") {
                return language == .english ? "Thinking…" : "思考中…"
            }
            return sharedKernelNonEmpty(title)
                ?? (language == .english ? "Thinking…" : "思考中…")
        case .status, .humanInteraction, .warning, .result:
            guard let detail = sharedKernelReadableEventDetail(event.detail) else {
                return sharedKernelNonEmpty(title)
            }
            guard let visibleTitle = sharedKernelNonEmpty(title),
                  detail != visibleTitle,
                  !detail.hasPrefix(visibleTitle) else {
                return detail
            }
            return "\(visibleTitle)\n\(detail)"
        }
    }

    private nonisolated static func sharedKernelReadableEventDetail(_ raw: String) -> String? {
        let visible = LingShuVisibleModelText.clean(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }

        let lowercased = visible.lowercased()
        let internalMarkers = [
            "\"file_name\"", "\"slides\"", "\"layout\"", "\"theme\"",
            "\"tool_calls\"", "\"arguments\"", "\"recursive\"", "\"command\"",
            "\"ok\"", "\"path\"", "[truncated]"
        ]
        let beginsLikePayload = visible.hasPrefix("{") || visible.hasPrefix("[")
        let markerCount = internalMarkers.reduce(into: 0) { count, marker in
            if lowercased.contains(marker) { count += 1 }
        }
        guard !beginsLikePayload || markerCount < 2 else { return nil }
        guard !lowercased.contains("[truncated]") else { return nil }
        return visible
    }

    private nonisolated static func sharedKernelNonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
