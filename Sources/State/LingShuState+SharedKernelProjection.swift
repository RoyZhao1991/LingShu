import Foundation

struct LingShuSharedKernelBubbleProjection: Sendable {
    var taskID: String
    var visibleText: String?
    var isLoading: Bool
    var status: LingShuKernelTaskStatus
    var pendingQuestion: String?
}

struct LingShuSharedKernelTaskProjection: Sendable {
    var record: LingShuTaskExecutionRecord
    var bubble: LingShuSharedKernelBubbleProjection?
}

struct LingShuSharedKernelProjectionBatch: Sendable {
    var allKernelIDs: Set<String>
    var activeKernelIDs: Set<String>
    var fingerprints: [String: Int]
    var changedTasks: [LingShuSharedKernelTaskProjection]
    var memory: LingShuKernelMemorySnapshot?
    var loopEngines: [LingShuKernelLoopEngineRecord]
}

@MainActor
extension LingShuState {
    /// Builds an immutable frontend projection off the main actor. The runtime snapshot remains
    /// canonical; SwiftUI receives only records whose semantic fingerprint changed.
    nonisolated static func prepareSharedKernelProjection(
        _ snapshot: LingShuKernelRuntimeSnapshot,
        existingRecords: [String: LingShuTaskExecutionRecord],
        previousFingerprints: [String: Int],
        english: Bool
    ) -> LingShuSharedKernelProjectionBatch {
        let eventsByTask = Dictionary(grouping: snapshot.events, by: \.taskId)
            .mapValues { $0.sorted { $0.sequence < $1.sequence } }
        let lineageIDs = Dictionary(grouping: snapshot.tasks) { task in
            task.rootTaskId ?? task.id
        }.mapValues { tasks in
            tasks.map { $0.id.uuidString.lowercased() }.sorted()
        }
        var messagesByID: [UUID: LingShuKernelChatMessage] = [:]
        for message in snapshot.messages {
            messagesByID[message.id] = message
        }

        var fingerprints: [String: Int] = [:]
        var changedTasks: [LingShuSharedKernelTaskProjection] = []
        var allKernelIDs = Set<String>()
        var activeKernelIDs = Set<String>()
        for task in snapshot.tasks {
            let taskID = task.id.uuidString.lowercased()
            let events = eventsByTask[task.id] ?? []
            let assistant = messagesByID[task.assistantMessageId]
            let fingerprint = sharedKernelProjectionFingerprint(
                task: task,
                events: events,
                assistant: assistant,
                english: english
            )
            fingerprints[taskID] = fingerprint
            allKernelIDs.insert(taskID)
            if task.status == .queued || task.status == .understanding || task.status == .running {
                activeKernelIDs.insert(taskID)
            }
            guard previousFingerprints[taskID] != fingerprint else { continue }

            let record = makeSharedKernelTaskRecord(
                task,
                events: events,
                lineageIDs: lineageIDs[task.rootTaskId ?? task.id] ?? [],
                existing: existingRecords[taskID],
                english: english
            )
            let bubble = makeSharedKernelBubbleProjection(
                task,
                assistant: assistant,
                events: events,
                english: english
            )
            changedTasks.append(.init(record: record, bubble: bubble))
        }
        return LingShuSharedKernelProjectionBatch(
            allKernelIDs: allKernelIDs,
            activeKernelIDs: activeKernelIDs,
            fingerprints: fingerprints,
            changedTasks: changedTasks,
            memory: snapshot.memory,
            loopEngines: snapshot.loopEngines
        )
    }

    /// Lightweight semantic version for a task projection. It intentionally includes streamed
    /// assistant/event text, because some compatible providers do not advance `updatedAt` for
    /// every chunk.
    nonisolated static func sharedKernelProjectionFingerprint(
        task: LingShuKernelTaskRecord,
        events: [LingShuKernelRuntimeEvent],
        assistant: LingShuKernelChatMessage?,
        english: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(english)
        hasher.combine(task.id)
        hasher.combine(task.status.rawValue)
        hasher.combine(task.updatedAt)
        hasher.combine(task.title)
        hasher.combine(task.summary)
        hasher.combine(task.error)
        hasher.combine(task.pendingQuestion)
        hasher.combine(task.participantName)
        hasher.combine(task.role.rawValue)
        hasher.combine(task.parentTaskId)
        hasher.combine(task.rootTaskId)
        if let goal = task.goalSpec {
            hasher.combine(goal.objective)
            hasher.combine(goal.kind.rawValue)
            hasher.combine(goal.outputMode.rawValue)
            hasher.combine(goal.referenceScope.rawValue)
            hasher.combine(goal.referenceConfidence.rawValue)
            goal.successCriteria.forEach { hasher.combine($0) }
            goal.constraints.forEach { hasher.combine($0) }
            goal.boundaries.forEach { hasher.combine($0) }
            goal.openQuestions.forEach { hasher.combine($0) }
        }
        for step in task.steps {
            hasher.combine(step.id)
            hasher.combine(step.status.rawValue)
            hasher.combine(step.updatedAt)
            hasher.combine(step.title)
            hasher.combine(step.detail)
        }
        for artifact in task.artifacts {
            hasher.combine(artifact.id)
            hasher.combine(artifact.path)
            hasher.combine(artifact.modifiedAt)
            hasher.combine(artifact.sizeBytes)
        }
        for event in events {
            hasher.combine(event.id)
            hasher.combine(event.sequence)
            hasher.combine(event.state.rawValue)
            hasher.combine(event.updatedAt)
            hasher.combine(event.title)
            hasher.combine(event.detail)
        }
        if let assistant {
            hasher.combine(assistant.id)
            hasher.combine(assistant.state.rawValue)
            hasher.combine(assistant.text)
        }
        return hasher.finalize()
    }

    private nonisolated static func makeSharedKernelTaskRecord(
        _ task: LingShuKernelTaskRecord,
        events: [LingShuKernelRuntimeEvent],
        lineageIDs: [String],
        existing: LingShuTaskExecutionRecord?,
        english: Bool
    ) -> LingShuTaskExecutionRecord {
        let language: LingShuVoiceLanguage = english ? .english : .chinese
        let id = task.id.uuidString.lowercased()
        let createdAt = Self.sharedKernelDate(task.createdAt)
        let updatedAt = Self.sharedKernelDate(task.updatedAt)
        let goalSpec = task.goalSpec.map(Self.sharedKernelGoalSpec)
        var participants = task.role == .main ? [english ? "You" : "你"] : []
        participants.append(task.participantName)
        participants.append(contentsOf: events.map(\.actor))
        participants = participants.reduce(into: []) { result, participant in
            if !participant.isEmpty, !result.contains(participant) { result.append(participant) }
        }
        let messages = events.map { event in
            LingShuTaskExecutionMessage(
                id: event.id.uuidString.lowercased(),
                timestamp: Self.sharedKernelDate(event.updatedAt),
                actor: event.actor,
                role: Self.sharedKernelEventRole(event.kind, language: language),
                kind: Self.sharedKernelMessageKind(event.kind),
                text: event.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? event.title
                    : "\(event.title)\n\(event.detail)"
            )
        }
        let artifacts = task.artifacts.map { artifact in
            let path = artifact.path
            let old = existing?.artifacts.first(where: { $0.location == path })
            let modified = Self.sharedKernelDate(artifact.modifiedAt)
            return LingShuTaskExecutionArtifact(
                id: artifact.id.uuidString.lowercased(),
                title: artifact.title,
                location: path,
                producer: task.participantName,
                createdAt: modified,
                operation: old == nil ? .created : (old?.createdAt == modified ? old?.operation : .modified)
            )
        }
        let plan = task.steps.map { step in
            LingShuPlanStep(
                id: step.id.uuidString.lowercased(),
                title: step.detail.isEmpty ? step.title : "\(step.title)：\(step.detail)",
                status: Self.sharedKernelPlanStatus(step.status)
            )
        }
        let roleName: String
        let semanticRole: String
        switch task.role {
        case .main:
            roleName = english ? "Main" : "主线程"
            semanticRole = "main"
        case .worker:
            roleName = english ? "Worker" : "执行者"
            semanticRole = "maker"
        case .checker:
            roleName = english ? "Checker" : "审查员"
            semanticRole = "checker"
        }
        let slot = LingShuTaskRoleSlot(
            id: "kernel-role-\(id)",
            roleID: task.role.rawValue,
            roleTitle: roleName,
            agentID: "runtime-kernel:\(id)",
            agentName: task.participantName,
            semanticRole: semanticRole,
            status: Self.sharedKernelRoleStatus(task.status)
        )
        let summary = task.summary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? task.error?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.sharedKernelStatusText(task.status, language: language)
        let mappedStatus = Self.sharedKernelTaskStatus(
            task.status,
            goal: task.goalSpec,
            hasArtifacts: !task.artifacts.isEmpty
        )
        var record = LingShuTaskExecutionRecord(
            id: id,
            title: task.title,
            prompt: task.prompt,
            status: mappedStatus,
            summary: summary,
            participants: participants,
            roleSlots: [slot],
            relatedRecordIDs: lineageIDs.filter { $0 != id },
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages,
            artifacts: artifacts,
            plan: plan,
            designScore: existing?.designScore,
            designIssues: existing?.designIssues ?? [],
            codeChanges: existing?.codeChanges,
            goal: goalSpec?.objective ?? task.title,
            goalSpec: goalSpec,
            gapAnalysis: existing?.gapAnalysis,
            acceptanceChecks: existing?.acceptanceChecks,
            acceptanceReport: existing?.acceptanceReport,
            capabilityRequirements: existing?.capabilityRequirements,
            acquisitionAttempts: existing?.acquisitionAttempts,
            capabilityProbeObservations: existing?.capabilityProbeObservations,
            taskOutcome: existing?.taskOutcome,
            effectVerificationReport: existing?.effectVerificationReport,
            threadCommit: existing?.threadCommit,
            workflowRuns: existing?.workflowRuns ?? []
        )
        _ = record.refreshThreadCommit(
            status: mappedStatus,
            summary: summary,
            parentTaskId: task.parentTaskId?.uuidString.lowercased(),
            now: updatedAt
        )
        return record
    }

    private nonisolated static func makeSharedKernelBubbleProjection(
        _ task: LingShuKernelTaskRecord,
        assistant: LingShuKernelChatMessage?,
        events: [LingShuKernelRuntimeEvent],
        english: Bool
    ) -> LingShuSharedKernelBubbleProjection? {
        guard task.role == .main else { return nil }
        let language: LingShuVoiceLanguage = english ? .english : .chinese
        let taskID = task.id.uuidString.lowercased()
        let latestEvent = events.last
        let progress = latestEvent.flatMap {
            Self.sharedKernelUserFacingEventText($0, language: language)
        }
        let assistantVisible = assistant.flatMap { message in
            LingShuVisibleModelText.clean(message.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }
        let summaryVisible = LingShuVisibleModelText.clean(task.summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let effectiveStatus: LingShuKernelTaskStatus = task.status == .failed ? .needsRecovery : task.status
        let visible: String?
        switch effectiveStatus {
        case .completed:
            visible = assistantVisible ?? summaryVisible ?? progress
        case .cancelled:
            // Manual termination seals the cumulative assistant transcript. A task summary may
            // describe only its latest phase and must never hide work already shown to the user.
            visible = assistantVisible ?? summaryVisible ?? progress
        case .queued, .understanding, .running, .needsRecovery, .needsUserAction:
            // The assistant message is the cumulative Loop transcript. Runtime events remain in
            // the execution record and are only a fallback before any visible model text exists.
            visible = assistantVisible ?? progress ?? summaryVisible
        case .failed:
            visible = summaryVisible ?? assistantVisible ?? progress
        }
        return LingShuSharedKernelBubbleProjection(
            taskID: taskID,
            visibleText: visible,
            isLoading: effectiveStatus == .queued
                || effectiveStatus == .understanding
                || effectiveStatus == .running
                || effectiveStatus == .needsRecovery,
            status: effectiveStatus,
            pendingQuestion: task.pendingQuestion
        )
    }

    func applySharedKernelBubbleProjection(_ projection: LingShuSharedKernelBubbleProjection?) {
        guard let projection,
              let bubbleID = sharedKernelBubbleIDs[projection.taskID],
              let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) else { return }
        var updated = chatMessages[index]
        if let visibleText = projection.visibleText, updated.text != visibleText {
            updated.text = visibleText
        }
        updated.taskRecordID = projection.taskID
        updated.isLoading = projection.isLoading
        updated.thinkingPreview = nil
        if updated != chatMessages[index] {
            chatMessages[index] = updated
        }

        if projection.status == .needsUserAction,
           chatMessages[index].awaitingInputForRecordID != projection.taskID {
            dispatchedTaskBubbles[projection.taskID] = bubbleID
            markDispatchedBubbleAwaitingInput(
                recordID: projection.taskID,
                question: projection.pendingQuestion ?? loc("需要你的输入后才能继续。", "Your input is required to continue.")
            )
        } else if projection.status.isTerminal {
            chatMessages[index].awaitingInputForRecordID = nil
            chatMessages[index].humanInteraction = nil
            chatMessages[index].choices = nil
            chatMessages[index].form = nil
            if let request = pendingDispatchedHumanInteractions.removeValue(forKey: projection.taskID) {
                humanInteractionProbeTasks.removeValue(forKey: request.id)?.cancel()
                clearHardHumanInteraction(requestID: request.id)
            }
            dispatchedTaskBubbles.removeValue(forKey: projection.taskID)
        }
    }

    func answerSharedKernelTaskIfNeeded(
        recordID: String,
        answer: String,
        displayAnswer: String?,
        appendUserMessage: Bool = true
    ) -> Bool {
        // A choice/form callback can arrive after the cancellation snapshot. Consume that stale
        // callback locally so the generic dispatched-task fallback cannot revive the sealed task.
        if taskExecutionRecords.first(where: { $0.id == recordID })?.status == .terminated {
            if let request = pendingDispatchedHumanInteractions.removeValue(forKey: recordID) {
                humanInteractionProbeTasks.removeValue(forKey: request.id)?.cancel()
                clearHardHumanInteraction(requestID: request.id)
            }
            if let index = chatMessages.lastIndex(where: { $0.awaitingInputForRecordID == recordID }) {
                chatMessages[index].awaitingInputForRecordID = nil
                chatMessages[index].humanInteraction = nil
                chatMessages[index].choices = nil
                chatMessages[index].form = nil
                chatMessages[index].isLoading = false
            }
            dispatchedTaskBubbles.removeValue(forKey: recordID)
            sharedKernelActiveThreadIDs.remove(recordID)
            activeTaskThreadRecordIDs.remove(recordID)
            return true
        }
        guard LingShuRuntimeEnvironment.usesSharedRuntimeKernel,
              sharedKernelKnownThreadIDs.contains(recordID),
              let threadID = UUID(uuidString: recordID) else { return false }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let request = pendingDispatchedHumanInteractions.removeValue(forKey: recordID) {
            humanInteractionProbeTasks.removeValue(forKey: request.id)?.cancel()
            clearHardHumanInteraction(requestID: request.id)
        }
        let visibleAnswer = (displayAnswer ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        let questionIndex = sharedKernelBubbleIDs[recordID]
            .flatMap { bubbleID in chatMessages.firstIndex(where: { $0.id == bubbleID }) }
            ?? chatMessages.lastIndex(where: { $0.awaitingInputForRecordID == recordID })
        if let index = questionIndex {
            chatMessages[index].awaitingInputForRecordID = nil
            chatMessages[index].resolvedChoice = visibleAnswer
            chatMessages[index].isLoading = false
        }
        if appendUserMessage {
            chatMessages.append(.init(
                speaker: loc("你", "You"),
                text: visibleAnswer,
                isUser: true,
                taskRecordID: recordID
            ))
        }
        let continuation = ChatMessage(
            speaker: loc("灵枢", "Nous"),
            text: "",
            isUser: false,
            isLoading: true,
            taskRecordID: recordID
        )
        chatMessages.append(continuation)
        sharedKernelBubbleIDs[recordID] = continuation.id
        dispatchedTaskBubbles[recordID] = continuation.id
        requestChatScrollToLatestForUserSend()
        sharedKernelActiveThreadIDs.insert(recordID)
        activeTaskThreadRecordIDs.insert(recordID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sharedKernelRuntime.resume(threadID: threadID, answer: trimmed)
                self.startSharedKernelPolling()
            } catch {
                self.failSharedKernelBubble(recordID: recordID, message: error.localizedDescription)
            }
        }
        return true
    }

    func stopSharedKernelTaskIfNeeded(recordID: String) -> Bool {
        guard LingShuRuntimeEnvironment.usesSharedRuntimeKernel,
              sharedKernelKnownThreadIDs.contains(recordID),
              let threadID = UUID(uuidString: recordID) else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sharedKernelRuntime.cancel(threadID: threadID)
                self.startSharedKernelPolling()
            } catch {
                self.failSharedKernelBubble(recordID: recordID, message: error.localizedDescription)
            }
        }
        return true
    }

    func failSharedKernelBubbles(_ message: String) {
        for recordID in sharedKernelActiveThreadIDs {
            failSharedKernelBubble(recordID: recordID, message: message)
        }
        sharedKernelActiveThreadIDs.removeAll()
        activeTaskThreadRecordIDs.subtract(sharedKernelKnownThreadIDs)
    }

    /// 宿主到共享内核的快照通道暂时失败时只更新可见进度，不结束根任务、
    /// 不移除活跃线程。轮询会按退避继续，恢复后仍投影到同一个气泡。
    func markSharedKernelBubblesRetrying(_ message: String) {
        for recordID in sharedKernelActiveThreadIDs {
            guard let bubbleID = sharedKernelBubbleIDs[recordID],
                  let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) else { continue }
            chatMessages[index].text = loc(
                "运行通道暂时中断，正在保留断点重试：\(message)",
                "The runtime channel was interrupted. Retrying from the saved checkpoint: \(message)"
            )
            chatMessages[index].isLoading = true
        }
    }

    func failSharedKernelBubble(recordID: String, message: String) {
        if let bubbleID = sharedKernelBubbleIDs[recordID],
           let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[index].text = loc(
                "共享内核需要恢复，目标和上下文已保留：\(message)",
                "The shared runtime needs recovery. The goal and context are preserved: \(message)"
            )
            chatMessages[index].isLoading = false
        }
        sharedKernelActiveThreadIDs.remove(recordID)
        activeTaskThreadRecordIDs.remove(recordID)
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
