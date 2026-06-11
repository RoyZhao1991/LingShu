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
    func materializeTaskArtifacts(
        for userPrompt: String,
        route: CodexRoutePayload?,
        reply: String,
        taskRecordID: String?
    ) -> [LingShuMaterializedArtifact] {
        let artifacts = engineeringArtifactService.materializeArtifacts(
            prompt: userPrompt,
            route: route,
            reply: reply,
            workingDirectory: codexWorkingDirectory
        )
        guard !artifacts.isEmpty else { return [] }

        for artifact in artifacts {
            appendTaskRecordArtifact(
                taskRecordID,
                title: artifact.title,
                location: artifact.location,
                producer: artifact.producer
            )
        }

        let manifest = artifacts
            .map { "\($0.title)：\($0.location)" }
            .joined(separator: "\n")
        appendTaskRecordMessage(
            taskRecordID,
            actor: "产出物",
            role: "交付清单",
            kind: .result,
            text: "已生成 \(artifacts.count) 个可检查产出物，并挂入本轮任务记录。\n\(manifest)"
        )
        appendTrace(
            kind: .result,
            actor: "产出物",
            title: "交付清单",
            detail: manifest
        )

        return artifacts
    }

    func linkRelatedTaskRecord(_ recordID: String?, relatedRecordID: String?, title: String) {
        guard let recordID,
              let relatedRecordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }),
              taskExecutionRecordLookup.contains(where: { $0.id == relatedRecordID }) else { return }

        taskExecutionRecords[index].linkRelatedRecord(relatedRecordID)
        taskExecutionRecords[index].append(
            actor: "记忆",
            role: "执行记忆",
            kind: .memory,
            text: "已关联历史任务流程：\(title)。本轮执行记录会连带展示此前的执行过程。"
        )
        persistTaskExecutionRecords()
    }

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

    func queueTaskRecord(_ recordID: String?, summary: String) {
        guard let recordID,
              let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }

        taskExecutionRecords[index].finish(status: .queued, summary: summary)
        persistTaskExecutionRecords()
    }

    func upsertTaskThread(
        id: String,
        fingerprint: String,
        prompt: String,
        memoryStatus: String,
        restored: Bool,
        recordID: String?
    ) {
        if let index = taskThreads.firstIndex(where: { $0.id == id }) {
            taskThreads[index].fingerprint = fingerprint
            if let recordID {
                taskThreads[index].start(recordID: recordID, prompt: prompt)
            } else {
                taskThreads[index].prompt = prompt
                taskThreads[index].updatedAt = Date()
            }
            taskThreads[index].memoryStatus = memoryStatus
            activeTaskThread = taskThreads[index]
        } else {
            let thread = LingShuTaskThread.create(
                id: id,
                fingerprint: fingerprint,
                prompt: prompt,
                memoryStatus: memoryStatus,
                restored: restored,
                recordID: recordID
            )
            taskThreads.insert(thread, at: 0)
            activeTaskThread = thread
        }
        trimDormantTaskThreads()
    }

    func enqueueTaskSegment(threadID: String, fingerprint: String, prompt: String, recordID: String?, reason: String) {
        guard let recordID else { return }
        if let index = taskThreads.firstIndex(where: { $0.id == threadID }) {
            taskThreads[index].enqueue(recordID: recordID, prompt: prompt)
        } else {
            var thread = LingShuTaskThread.create(
                id: threadID,
                fingerprint: fingerprint,
                prompt: prompt,
                memoryStatus: "等待前序任务完成后加载执行记忆。",
                restored: false,
                recordID: nil
            )
            thread.enqueue(recordID: recordID, prompt: prompt)
            taskThreads.insert(thread, at: 0)
        }
        queueTaskRecord(recordID, summary: "已进入任务队列，等待同线程前序段完成。")
        appendTaskRecordMessage(recordID, actor: "任务队列", role: "线程调度", kind: .router, text: reason)
        trimDormantTaskThreads()
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
        taskExecutionJournal.saveRecords(taskExecutionRecords)
        taskExecutionRecords = taskExecutionJournal.loadRecords()
        archivedTaskExecutionRecords = taskExecutionJournal.loadArchivedRecords()
    }

    func formatElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
