import Foundation

@MainActor
extension LingShuState {
    @discardableResult
    func commitTaskThreadState(
        recordID: String?,
        status: LingShuTaskExecutionStatus? = nil,
        phase: LingShuTaskThreadCommit.Phase? = nil,
        summary: String? = nil,
        blockingReason: String? = nil,
        requiredUserAction: String? = nil,
        checkerVerdict: String? = nil,
        persist: Bool = true,
        trace: Bool = true
    ) -> LingShuTaskThreadCommit? {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return nil }

        if let status { taskExecutionRecords[index].status = status }
        if let summary {
            let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { taskExecutionRecords[index].summary = clean }
        }

        let commit = taskExecutionRecords[index].refreshThreadCommit(
            status: status,
            phase: phase,
            summary: summary,
            blockingReason: blockingReason,
            requiredUserAction: requiredUserAction,
            checkerVerdict: checkerVerdict
        )
        mainThreadKernel.observeTaskThreadCommit(commit)

        if trace {
            appendTrace(kind: .runtime, actor: "任务账本", title: "线程提交", detail: commit.ledgerLine)
        } else {
            recordWorldEvent(kind: .task, source: "任务账本", summary: "线程提交:\(commit.status.rawValue)", payload: [
                "recordID": commit.taskId,
                "traceID": commit.traceId,
                "phase": commit.phase.rawValue
            ])
        }

        if persist { persistTaskExecutionRecords() }
        return commit
    }

    @discardableResult
    func refreshTaskThreadHeartbeat(
        recordID: String?,
        phase: LingShuTaskThreadCommit.Phase? = nil,
        summary: String? = nil
    ) -> LingShuTaskThreadCommit? {
        commitTaskThreadState(
            recordID: recordID,
            phase: phase,
            summary: summary,
            persist: false,
            trace: false
        )
    }

    func globalTaskThreadLedgerContext(limit: Int = 8) -> String {
        let commits = taskThreadLedgerCommits(limit: limit)
        guard !commits.isEmpty else { return "" }
        let lines = commits.enumerated().map { offset, commit in
            let index = offset + 1
            return "\(index). \(commit.ledgerLine)"
        }.joined(separator: "\n")
        return """
        【全局任务线程账本(只用于判断任务运行/续接/收尾/产出状态;不是当前请求,不要把这里的旧任务当成新指令)】
        \(lines)
        """
    }

    func globalTaskThreadLedgerPayload(limit: Int = 12) -> [[String: Any]] {
        taskThreadLedgerCommits(limit: limit).map(Self.taskThreadCommitPayload)
    }

    private func taskThreadLedgerCommits(limit: Int) -> [LingShuTaskThreadCommit] {
        func commit(for record: LingShuTaskExecutionRecord) -> LingShuTaskThreadCommit {
            record.threadCommit ?? LingShuTaskThreadCommit.make(
                record: record,
                status: record.status,
                phase: LingShuTaskThreadCommit.phase(for: record.status),
                summary: record.summary,
                now: record.updatedAt
            )
        }

        func activityDate(record: LingShuTaskExecutionRecord, commit: LingShuTaskThreadCommit) -> Date {
            max(record.updatedAt, commit.committedAt, commit.lastHeartbeatAt)
        }

        let entries: [(record: LingShuTaskExecutionRecord, commit: LingShuTaskThreadCommit)] = taskExecutionRecords
            .map { record in (record: record, commit: commit(for: record)) }
        let sorted = entries.sorted(by: { left, right in
                let leftDate = activityDate(record: left.record, commit: left.commit)
                let rightDate = activityDate(record: right.record, commit: right.commit)
                if leftDate != rightDate { return leftDate > rightDate }
                if left.commit.isOpen != right.commit.isOpen { return left.commit.isOpen && !right.commit.isOpen }
                return left.record.createdAt > right.record.createdAt
            })
        return sorted.prefix(max(1, limit)).map(\.commit)
    }

    nonisolated static func taskThreadCommitPayload(_ commit: LingShuTaskThreadCommit) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var object: [String: Any] = [
            "taskId": commit.taskId,
            "status": commit.status.rawValue,
            "phase": commit.phase.rawValue,
            "objective": commit.objective,
            "progressSummary": commit.progressSummary,
            "artifacts": commit.artifacts.map {
                ["title": $0.title, "location": $0.location, "producer": $0.producer]
            },
            "lastHeartbeatAt": iso.string(from: commit.lastHeartbeatAt),
            "committedAt": iso.string(from: commit.committedAt),
            "traceId": commit.traceId,
            "isOpen": commit.isOpen
        ]
        if let parentTaskId = commit.parentTaskId { object["parentTaskId"] = parentTaskId }
        if let blockingReason = commit.blockingReason { object["blockingReason"] = blockingReason }
        if let requiredUserAction = commit.requiredUserAction { object["requiredUserAction"] = requiredUserAction }
        if let checkerVerdict = commit.checkerVerdict { object["checkerVerdict"] = checkerVerdict }
        return object
    }
}
