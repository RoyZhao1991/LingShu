import Foundation

@MainActor
extension LingShuState {
    func openTaskRecord(_ recordID: String?) {
        guard let recordID, taskExecutionRecordLookup.contains(where: { $0.id == recordID }) else { return }
        selectedTaskRecordID = recordID
        isTaskRecordPresented = true
    }

    func createTaskExecutionRecord(for prompt: String) -> String {
        let record = LingShuTaskExecutionRecord.create(prompt: prompt)
        taskExecutionJournal.upsert(record, into: &taskExecutionRecords)
        persistTaskExecutionRecords()
        return record.id
    }

    func appendTaskRecordMessage(
        _ recordID: String?,
        actor: String,
        role: String,
        kind: LingShuTaskExecutionMessageKind,
        text: String
    ) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        taskExecutionRecords[index].append(actor: actor, role: role, kind: kind, text: text)
        persistTaskExecutionRecords()
    }

    func appendTaskRecordArtifact(
        _ recordID: String?,
        title: String,
        location: String,
        producer: String
    ) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        taskExecutionRecords[index].appendArtifact(title: title, location: location, producer: producer)
        persistTaskExecutionRecords()
    }

    @discardableResult
    func applyTaskRecordRoute(_ recordID: String?, route: CodexRoutePayload) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        let agentNames = route.agents.map(\.agent)
        let summary = route.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        taskExecutionRecords[index].applyRoute(
            needsAgents: route.needsAgents,
            agents: agentNames,
            summary: summary
        )
        persistTaskExecutionRecords()
    }

    func finishTaskRecord(
        _ recordID: String?,
        status: LingShuTaskExecutionStatus,
        summary: String
    ) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        taskExecutionRecords[index].finish(status: status, summary: summary)
        persistTaskExecutionRecords()
        if status == .answered || status == .completed || status == .blocked {
            markTaskSegmentFinished(recordID: recordID, blocked: status == .blocked)
            DispatchQueue.main.async { [weak self] in
                self?.startNextQueuedTaskIfAvailable()
            }
        }
    }

    func markTaskSegmentFinished(recordID: String?, blocked: Bool = false) {
        guard let recordID else { return }
        for index in taskThreads.indices {
            taskThreads[index].complete(recordID: recordID, blocked: blocked)
        }
        trimDormantTaskThreads()
    }

    func startNextQueuedTaskIfAvailable(preferredThreadID: String? = nil) {
        let candidateIndex: Int?
        if let preferredThreadID,
           let preferredIndex = taskThreads.firstIndex(where: { $0.id == preferredThreadID && !$0.hasRunningSegment && $0.hasQueuedSegments }) {
            candidateIndex = preferredIndex
        } else {
            candidateIndex = taskThreads.firstIndex(where: { !$0.hasRunningSegment && $0.hasQueuedSegments })
        }

        guard let index = candidateIndex,
              let segment = taskThreads[index].popNextWaitingSegment() else { return }

        let threadID = taskThreads[index].id
        activeTaskThread = taskThreads[index]
        appendTaskRecordMessage(segment.recordID, actor: "任务队列", role: "顺序执行", kind: .router, text: "前序段已完成，现在开始处理该任务线程的下一段。")
        chatMessages.append(.init(speaker: "灵枢", text: "轮到任务队列的下一段了，我继续处理。", isUser: false, taskRecordID: segment.recordID))
        _ = submitTextInput(
            segment.prompt,
            source: .plugin("任务队列"),
            existingTaskRecordID: segment.recordID,
            appendUserMessage: false,
            bypassActiveGate: true,
            forcedThreadID: threadID
        )
    }

    func trimDormantTaskThreads() {
        if taskThreads.count > 24 {
            taskThreads.removeLast(taskThreads.count - 24)
        }
    }

    func persistTaskExecutionRecords() {
        let saved = taskExecutionJournal.saveRecords(taskExecutionRecords)
        if taskExecutionRecords != saved.active {
            taskExecutionRecords = saved.active
        }
        if archivedTaskExecutionRecords != saved.archived {
            archivedTaskExecutionRecords = saved.archived
        }
    }

    func formatElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
