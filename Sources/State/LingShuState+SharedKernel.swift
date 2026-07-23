import Foundation

@MainActor
extension LingShuState {
    var sharedKernelDataDirectory: String {
        LingShuRuntimeEnvironment.applicationSupportDirectory()
            .appendingPathComponent("LingShu/RuntimeCore", isDirectory: true)
            .path
    }

    func sharedKernelSettings() throws -> LingShuKernelRuntimeSettings {
        let protocolName = selectedModelPreset?.protocolName ?? ""
        let requestFormat = LingShuModelGateway().requestFormat(
            provider: modelProvider,
            endpoint: endpoint,
            protocolName: protocolName
        )
        let protocolKind: LingShuKernelProviderProtocol
        switch requestFormat {
        case .responses:
            protocolKind = .openAIResponses
        case .chatCompletions:
            protocolKind = .openAIChatCompletions
        case .anthropicMessages:
            protocolKind = .anthropicMessages
        case .hostAdapter:
            throw LingShuSharedKernelRuntimeError.rpc(
                loc(
                    "当前通道需要宿主 SDK 适配，不能作为 HTTP 兼容接口运行：\(protocolName)",
                    "This channel requires a host SDK adapter and cannot run as an HTTP-compatible endpoint: \(protocolName)"
                )
            )
        }
        return LingShuKernelRuntimeSettings(
            locale: language == .english ? .en : .zhCN,
            providerId: selectedModelPreset?.id ?? Self.sharedKernelProviderID(modelProvider),
            providerName: modelProvider,
            protocol: protocolKind,
            endpoint: endpoint,
            model: modelName,
            workspace: agentWorkingDirectory,
            executionPermissionMode: executionPermissionMode == .fullAccess ? .fullAccess : .sandbox,
            firstRunComplete: true
        )
    }

    func submitSharedKernelTurn(
        prompt: String,
        attachmentPaths: [String],
        reusePlaceholderID: UUID?
    ) {
        let placeholderID: UUID
        if let reusePlaceholderID,
           let index = chatMessages.firstIndex(where: { $0.id == reusePlaceholderID }) {
            chatMessages[index].text = loc("理解中…", "Understanding…")
            chatMessages[index].isLoading = true
            chatMessages[index].thinkingPreview = nil
            placeholderID = reusePlaceholderID
        } else {
            let placeholder = ChatMessage(
                speaker: loc("灵枢", "Nous"),
                text: loc("理解中…", "Understanding…"),
                isUser: false,
                isLoading: true
            )
            chatMessages.append(placeholder)
            placeholderID = placeholder.id
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sharedKernelRuntime.ensureStarted(dataDirectory: self.sharedKernelDataDirectory)
                _ = try await self.sharedKernelRuntime.configure(
                    settings: try self.sharedKernelSettings(),
                    apiKey: self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                    providerConfigured: self.isModelConnected
                )
                let receipt = try await self.sharedKernelRuntime.submit(
                    prompt: prompt,
                    attachmentPaths: attachmentPaths.filter { !$0.isEmpty }
                )
                let threadID = receipt.threadId.uuidString.lowercased()
                self.sharedKernelKnownThreadIDs.insert(threadID)
                self.sharedKernelActiveThreadIDs.insert(threadID)
                self.sharedKernelBubbleIDs[threadID] = placeholderID
                self.dispatchedTaskBubbles[threadID] = placeholderID
                if let index = self.chatMessages.firstIndex(where: { $0.id == placeholderID }) {
                    self.chatMessages[index].taskRecordID = threadID
                    self.chatMessages[index].text = receipt.queued
                        ? self.loc("已排队，前一任务结束后自动执行。", "Queued. It will run after the current task.")
                        : self.loc("理解中…", "Understanding…")
                }
                self.appendTrace(
                    kind: .route,
                    actor: "RuntimeKernel",
                    title: self.loc("共享内核接管", "Shared kernel accepted"),
                    detail: "thread=\(threadID) platform=macos queued=\(receipt.queued)"
                )
                self.startSharedKernelPolling()
            } catch {
                if let index = self.chatMessages.firstIndex(where: { $0.id == placeholderID }) {
                    self.chatMessages[index].text = self.loc(
                        "共享内核不可用：\(error.localizedDescription)",
                        "Shared runtime unavailable: \(error.localizedDescription)"
                    )
                    self.chatMessages[index].isLoading = false
                }
                self.appendTrace(
                    kind: .warning,
                    actor: "RuntimeKernel",
                    title: self.loc("共享内核启动失败", "Shared kernel failed to start"),
                    detail: error.localizedDescription
                )
                self.drainSerialInputsIfIdle()
            }
        }
    }

    func startSharedKernelPolling() {
        guard sharedKernelPollingTask == nil else { return }
        sharedKernelPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sharedKernelPollingTask = nil }
            var consecutiveErrors = 0
            while !Task.isCancelled {
                do {
                    let snapshot = try await self.sharedKernelRuntime.snapshot(providerConfigured: self.isModelConnected)
                    consecutiveErrors = 0
                    self.projectSharedKernelSnapshot(snapshot)
                    let hasRunnableTask = snapshot.tasks.contains {
                        $0.status == .queued || $0.status == .understanding || $0.status == .running
                    }
                    if !hasRunnableTask { break }
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        self.failSharedKernelBubbles(error.localizedDescription)
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.drainSerialInputsIfIdle()
        }
    }

    func projectSharedKernelSnapshot(_ snapshot: LingShuKernelRuntimeSnapshot) {
        guard snapshot.kernelAbiVersion == LingShuKernelABI.version else {
            failSharedKernelBubbles("ABI mismatch: \(snapshot.kernelAbiVersion)")
            return
        }
        let allKernelIDs = Set(snapshot.tasks.map { $0.id.uuidString.lowercased() })
        sharedKernelKnownThreadIDs.formUnion(allKernelIDs)
        let previouslyActive = sharedKernelActiveThreadIDs
        let nowActive = Set(snapshot.tasks.compactMap { task -> String? in
            switch task.status {
            case .queued, .understanding, .running:
                task.id.uuidString.lowercased()
            case .needsUserAction, .completed, .failed, .cancelled:
                nil
            }
        })
        sharedKernelActiveThreadIDs = nowActive
        activeTaskThreadRecordIDs.subtract(allKernelIDs)
        activeTaskThreadRecordIDs.formUnion(nowActive)

        let eventsByTask = Dictionary(grouping: snapshot.events, by: \LingShuKernelRuntimeEvent.taskId)
        let lineageIDs = Dictionary(grouping: snapshot.tasks) { task in
            task.rootTaskId ?? task.id
        }.mapValues { $0.map { $0.id.uuidString.lowercased() } }

        var recordsChanged = false
        for task in snapshot.tasks {
            let taskID = task.id.uuidString.lowercased()
            let oldRecord = taskExecutionRecords.first(where: { $0.id == taskID })
            let record = sharedKernelTaskRecord(
                task,
                events: eventsByTask[task.id] ?? [],
                lineageIDs: lineageIDs[task.rootTaskId ?? task.id] ?? [],
                existing: oldRecord
            )
            if oldRecord != record {
                taskExecutionJournal.upsert(record, into: &taskExecutionRecords)
                recordsChanged = true
            }
            projectSharedKernelBubble(
                task,
                messages: snapshot.messages,
                events: eventsByTask[task.id] ?? []
            )
        }
        if recordsChanged { persistTaskExecutionRecords() }

        let newlyFinished = previouslyActive.subtracting(nowActive)
        for recordID in newlyFinished {
            guard let record = taskExecutionRecords.first(where: { $0.id == recordID }),
                  record.status.isTerminal else { continue }
            if selectedTaskRecordID != recordID || !isTaskRecordPresented {
                unreadTaskThreadRecordIDs.insert(recordID)
            }
        }
        missionStatus = nowActive.isEmpty
            ? loc("待机中", "Standby")
            : loc("共享内核正在执行 \(nowActive.count) 个会话", "Shared kernel is running \(nowActive.count) session(s)")
    }

    private func sharedKernelTaskRecord(
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

    private func projectSharedKernelBubble(
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
        let progress = latestEvent.flatMap { event -> String? in
            let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? event.title.nonEmpty : "\(event.title)\n\(detail)"
        }
        let visible = task.status == .completed
            ? (assistant?.text.nonEmpty ?? task.summary.nonEmpty ?? progress)
            : (progress ?? assistant?.text.nonEmpty ?? task.summary.nonEmpty)
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

    private func failSharedKernelBubbles(_ message: String) {
        for recordID in sharedKernelActiveThreadIDs {
            failSharedKernelBubble(recordID: recordID, message: message)
        }
        sharedKernelActiveThreadIDs.removeAll()
        activeTaskThreadRecordIDs.subtract(sharedKernelKnownThreadIDs)
    }

    private func failSharedKernelBubble(recordID: String, message: String) {
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
