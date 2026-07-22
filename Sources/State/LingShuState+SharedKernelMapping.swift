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
        case .needsUserAction: .waitingForUser
        case .completed:
            goal?.outputMode == .chatReply && !hasArtifacts ? .answered : .completed
        case .failed: .failed
        case .cancelled: .failed
        }
    }

    nonisolated static func sharedKernelPlanStatus(_ status: LingShuKernelTaskStatus) -> LingShuPlanStep.Status {
        switch status {
        case .queued, .needsUserAction: .pending
        case .understanding, .running: .inProgress
        case .completed: .completed
        case .failed, .cancelled: .failed
        }
    }

    nonisolated static func sharedKernelRoleStatus(_ status: LingShuKernelTaskStatus) -> LingShuTaskRoleSlotStatus {
        switch status {
        case .queued, .needsUserAction: .pending
        case .understanding, .running: .running
        case .completed: .completed
        case .failed, .cancelled: .failed
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
        case .needsUserAction: english ? "Waiting for user" : "等待用户"
        case .completed: english ? "Completed" : "已完成"
        case .failed: english ? "Failed" : "失败"
        case .cancelled: english ? "Cancelled" : "已取消"
        }
    }
}
