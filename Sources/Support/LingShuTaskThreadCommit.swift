import Foundation

/// 子任务线程向灵枢主线程提交的最小运行态事实。
///
/// 这不是长期记忆,而是主线程做续接、收尾、排队、展示和故障恢复时必须同步读取的任务账本。
/// 完整 transcript 留在任务记录窗口;主线程只读这份薄状态。
struct LingShuTaskThreadCommit: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case planning = "planning"
        case executing = "executing"
        case checking = "checking"
        case delivering = "delivering"
        case waiting = "waiting"
        case failed = "failed"
    }

    struct ArtifactSnapshot: Codable, Equatable, Sendable {
        var title: String
        var location: String
        var producer: String
    }

    var taskId: String
    var parentTaskId: String?
    var status: LingShuTaskExecutionStatus
    var phase: Phase
    var objective: String
    var progressSummary: String
    var blockingReason: String?
    var requiredUserAction: String?
    var artifacts: [ArtifactSnapshot]
    var checkerVerdict: String?
    var lastHeartbeatAt: Date
    var committedAt: Date
    var traceId: String

    var isOpen: Bool {
        switch status {
        case .running, .queued, .dispatched, .analyzing, .acquiringCapability, .ready, .suspended:
            return true
        case .waitingForUser, .blocked, .partial, .needsRevision:
            return true
        case .answered, .completed, .verified, .failed:
            return false
        }
    }

    var ledgerLine: String {
        var pieces = [
            "id=\(taskId)",
            "状态=\(status.rawValue)",
            "阶段=\(phase.rawValue)",
            "目标=\(objective)"
        ]
        if !progressSummary.isEmpty { pieces.append("进展=\(progressSummary)") }
        if let blockingReason, !blockingReason.isEmpty { pieces.append("阻塞=\(blockingReason)") }
        if let requiredUserAction, !requiredUserAction.isEmpty { pieces.append("待用户=\(requiredUserAction)") }
        if !artifacts.isEmpty {
            pieces.append("产出=\(artifacts.map { $0.location }.joined(separator: "、"))")
        }
        if let checkerVerdict, !checkerVerdict.isEmpty { pieces.append("验收=\(checkerVerdict)") }
        return pieces.joined(separator: "；")
    }

    static func phase(for status: LingShuTaskExecutionStatus, fallback: Phase = .executing) -> Phase {
        switch status {
        case .queued, .analyzing:
            return .planning
        case .running, .dispatched, .ready, .acquiringCapability, .suspended:
            return fallback
        case .waitingForUser, .blocked, .partial, .needsRevision:
            return .waiting
        case .answered, .completed, .verified:
            return .delivering
        case .failed:
            return .failed
        }
    }

    static func make(
        record: LingShuTaskExecutionRecord,
        status: LingShuTaskExecutionStatus,
        phase: Phase? = nil,
        summary: String,
        parentTaskId: String? = nil,
        blockingReason: String? = nil,
        requiredUserAction: String? = nil,
        checkerVerdict: String? = nil,
        now: Date = Date()
    ) -> LingShuTaskThreadCommit {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = record.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? record.title : record.goal
        return .init(
            taskId: record.id,
            parentTaskId: parentTaskId ?? record.threadCommit?.parentTaskId,
            status: status,
            phase: phase ?? Self.phase(for: status),
            objective: objective,
            progressSummary: cleanSummary.isEmpty ? record.summary : cleanSummary,
            blockingReason: blockingReason,
            requiredUserAction: requiredUserAction,
            artifacts: record.artifacts.map {
                .init(title: $0.title, location: $0.location, producer: $0.producer)
            },
            checkerVerdict: checkerVerdict ?? record.threadCommit?.checkerVerdict,
            lastHeartbeatAt: now,
            committedAt: now,
            traceId: "task-commit-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))"
        )
    }
}

extension LingShuTaskExecutionRecord {
    mutating func refreshThreadCommit(
        status: LingShuTaskExecutionStatus? = nil,
        phase: LingShuTaskThreadCommit.Phase? = nil,
        summary: String? = nil,
        parentTaskId: String? = nil,
        blockingReason: String? = nil,
        requiredUserAction: String? = nil,
        checkerVerdict: String? = nil,
        now: Date = Date()
    ) -> LingShuTaskThreadCommit {
        let nextStatus = status ?? self.status
        let nextSummary = summary ?? self.summary
        let commit = LingShuTaskThreadCommit.make(
            record: self,
            status: nextStatus,
            phase: phase,
            summary: nextSummary,
            parentTaskId: parentTaskId,
            blockingReason: blockingReason,
            requiredUserAction: requiredUserAction,
            checkerVerdict: checkerVerdict,
            now: now
        )
        self.threadCommit = commit
        self.updatedAt = now
        return commit
    }
}
