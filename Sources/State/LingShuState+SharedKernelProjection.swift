import Foundation

@MainActor
extension LingShuState {
    func sharedKernelTaskRecord(
        _ task: LingShuKernelTaskRecord,
        events: [LingShuKernelRuntimeEvent],
        lineageIDs: [String],
        existing: LingShuTaskExecutionRecord?
    ) -> LingShuTaskExecutionRecord {
        let id = task.id.uuidString.lowercased()
        let createdAt = Self.sharedKernelDate(task.createdAt)
        let updatedAt = Self.sharedKernelDate(task.updatedAt)
        let goalSpec = task.goalSpec.map(Self.sharedKernelGoalSpec)
        var participants = task.role == .main ? [loc("你", "You")] : []
        participants.append(task.participantName)
        participants.append(contentsOf: events.map(\.actor))
        participants = participants.reduce(into: []) { result, participant in
            if !participant.isEmpty, !result.contains(participant) { result.append(participant) }
        }
        let messages = events.sorted { $0.sequence < $1.sequence }.map { event in
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
            roleName = loc("主线程", "Main")
            semanticRole = "main"
        case .worker:
            roleName = loc("执行者", "Worker")
            semanticRole = "maker"
        case .checker:
            roleName = loc("审查员", "Checker")
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
        return LingShuTaskExecutionRecord(
            id: id,
            title: task.title,
            prompt: task.prompt,
            status: Self.sharedKernelTaskStatus(task.status, goal: task.goalSpec, hasArtifacts: !task.artifacts.isEmpty),
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
    }

    func projectSharedKernelBubble(
        _ task: LingShuKernelTaskRecord,
        messages: [LingShuKernelChatMessage],
        events: [LingShuKernelRuntimeEvent]
    ) {
        guard task.role == .main else { return }
        let taskID = task.id.uuidString.lowercased()
        guard let bubbleID = sharedKernelBubbleIDs[taskID],
              let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) else { return }
        let assistant = messages.last { $0.id == task.assistantMessageId }
        let latestEvent = events.max { $0.sequence < $1.sequence }
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
        let visible: String?
        switch task.status {
        case .completed:
            visible = assistantVisible ?? summaryVisible ?? progress
        case .failed, .cancelled:
            visible = summaryVisible ?? assistantVisible ?? progress
        case .queued, .understanding, .running, .needsUserAction:
            visible = progress ?? assistantVisible ?? summaryVisible
        }
        if let visible { chatMessages[index].text = visible }
        chatMessages[index].taskRecordID = taskID
        chatMessages[index].isLoading = task.status == .queued || task.status == .understanding || task.status == .running
        chatMessages[index].thinkingPreview = nil

        if task.status == .needsUserAction,
           chatMessages[index].awaitingInputForRecordID != taskID {
            dispatchedTaskBubbles[taskID] = bubbleID
            markDispatchedBubbleAwaitingInput(
                recordID: taskID,
                question: task.pendingQuestion ?? loc("需要你的输入后才能继续。", "Your input is required to continue.")
            )
        } else if task.status.isTerminal {
            chatMessages[index].awaitingInputForRecordID = nil
            chatMessages[index].humanInteraction = nil
            dispatchedTaskBubbles.removeValue(forKey: taskID)
        }
    }

    func answerSharedKernelTaskIfNeeded(
        recordID: String,
        answer: String,
        displayAnswer: String?
    ) -> Bool {
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
        if let index = chatMessages.firstIndex(where: { $0.awaitingInputForRecordID == recordID }) {
            chatMessages[index].awaitingInputForRecordID = nil
            chatMessages[index].resolvedChoice = visibleAnswer
            chatMessages[index].humanInteraction = nil
            chatMessages[index].text = loc("继续执行中…", "Resuming…")
            chatMessages[index].isLoading = true
        }
        chatMessages.append(.init(speaker: loc("你", "You"), text: visibleAnswer, isUser: true, taskRecordID: recordID))
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

    func failSharedKernelBubble(recordID: String, message: String) {
        if let bubbleID = sharedKernelBubbleIDs[recordID],
           let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[index].text = loc("共享内核中断：\(message)", "Shared runtime stopped: \(message)")
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
