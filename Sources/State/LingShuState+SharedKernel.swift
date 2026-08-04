import Foundation

@MainActor
extension LingShuState {
    var sharedKernelDataDirectory: String {
        LingShuRuntimeEnvironment.applicationSupportDirectory()
            .appendingPathComponent("LingShu/RuntimeCore", isDirectory: true)
            .path
    }

    /// Opens the canonical Rust task store as part of app launch so restart recovery and
    /// parent/child terminal reconciliation do not wait for the user's next message.
    /// This is deliberately configuration-free: it neither selects a provider nor starts a task.
    func prepareSharedKernelOnLaunch() async {
        guard LingShuRuntimeEnvironment.usesSharedRuntimeKernel else { return }
        do {
            try await sharedKernelRuntime.ensureStarted(dataDirectory: sharedKernelDataDirectory)
            let snapshot = try await sharedKernelRuntime.snapshot(providerConfigured: isModelConnected)
            await projectSharedKernelSnapshot(snapshot)
            if snapshot.tasks.contains(where: {
                $0.status == .queued || $0.status == .understanding || $0.status == .running
            }) {
                startSharedKernelPolling()
            }
            appendTrace(
                kind: .runtime,
                actor: "RuntimeKernel",
                title: loc("共享任务账本已同步", "Shared task ledger synchronized"),
                detail: "tasks=\(snapshot.tasks.count) active=\(snapshot.activeTaskId?.uuidString.lowercased() ?? "none")"
            )
        } catch {
            // Launch remains usable on legacy/test builds without the shared library. A real turn
            // will surface the same error in its own bubble if the runtime is still unavailable.
            appendTrace(
                kind: .warning,
                actor: "RuntimeKernel",
                title: loc("共享任务账本同步失败", "Shared task ledger synchronization failed"),
                detail: error.localizedDescription
            )
        }
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
            loopEngine: loopEngine.kernelKind,
            firstRunComplete: true
        )
    }

    func submitSharedKernelTurn(
        prompt: String,
        attachmentPaths: [String],
        reusePlaceholderID: UUID?,
        speechRequest: String,
        inputSource: LingShuDialogueInputSource
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
        registerSpeechIntent(for: placeholderID, request: speechRequest, source: inputSource)
        sharedKernelSubmissionsInFlight += 1

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sharedKernelSubmissionsInFlight = max(0, self.sharedKernelSubmissionsInFlight - 1); self.drainSerialInputsIfIdle() }
            do {
                try await self.sharedKernelRuntime.ensureStarted(dataDirectory: self.sharedKernelDataDirectory)
                _ = try await self.sharedKernelRuntime.configure(
                    settings: try self.sharedKernelSettings(),
                    apiKey: self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                    providerConfigured: self.isModelConnected
                )
                try await self.ensureSharedKernelLegacyMemoryImported()
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
                    await self.projectSharedKernelSnapshot(snapshot)
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

    func projectSharedKernelSnapshot(_ snapshot: LingShuKernelRuntimeSnapshot) async {
        guard snapshot.kernelAbiVersion == LingShuKernelABI.version else {
            failSharedKernelBubbles("ABI mismatch: \(snapshot.kernelAbiVersion)")
            return
        }
        let existingRecords = Dictionary(
            uniqueKeysWithValues: taskExecutionRecords.map { ($0.id, $0) }
        )
        let previousFingerprints = sharedKernelProjectionFingerprints
        let english = language == .english
        let batch = await Task.detached(priority: .userInitiated) {
            Self.prepareSharedKernelProjection(
                snapshot,
                existingRecords: existingRecords,
                previousFingerprints: previousFingerprints,
                english: english
            )
        }.value
        guard !Task.isCancelled else { return }

        sharedKernelProjectionFingerprints = batch.fingerprints
        if sharedKernelLoopEngines != batch.loopEngines {
            sharedKernelLoopEngines = batch.loopEngines
        }
        sharedKernelKnownThreadIDs.formUnion(batch.allKernelIDs)
        let previouslyActive = sharedKernelActiveThreadIDs
        let nowActive = batch.activeKernelIDs
        sharedKernelActiveThreadIDs = nowActive
        activeTaskThreadRecordIDs.subtract(batch.allKernelIDs)
        activeTaskThreadRecordIDs.formUnion(nowActive)

        var recordsChanged = false
        var recordIndexes = Dictionary(
            uniqueKeysWithValues: taskExecutionRecords.enumerated().map { ($0.element.id, $0.offset) }
        )
        for projection in batch.changedTasks {
            if let index = recordIndexes[projection.record.id] {
                if taskExecutionRecords[index] != projection.record {
                    taskExecutionRecords[index] = projection.record
                    recordsChanged = true
                }
            } else {
                recordIndexes[projection.record.id] = taskExecutionRecords.count
                taskExecutionRecords.append(projection.record)
                recordsChanged = true
            }
            applySharedKernelBubbleProjection(projection.bubble)
        }
        if recordsChanged {
            taskExecutionRecords.sort { $0.updatedAt > $1.updatedAt }
        }

        let newlyFinished = previouslyActive.subtracting(nowActive)
        if recordsChanged {
            scheduleSharedKernelRecordPersistence(immediate: !newlyFinished.isEmpty)
        }
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
        if let memory = batch.memory {
            mainMemoryStatus = loc(
                "Rust 热记忆 \(memory.hotCount) 条",
                "Rust hot memory: \(memory.hotCount)"
            )
            coldMemoryStatus = loc(
                "Rust 冷记忆 \(memory.coldCount) 条",
                "Rust cold memory: \(memory.coldCount)"
            )
        }
    }

    /// Coalesces the Swift task journal to at most one write per second while a task streams.
    /// Terminal transitions flush immediately, so the UI never trades correctness for smoothness.
    private func scheduleSharedKernelRecordPersistence(immediate: Bool) {
        if immediate {
            sharedKernelRecordPersistenceTask?.cancel()
            sharedKernelRecordPersistenceTask = nil
            sharedKernelLastRecordPersistenceAt = Date()
            persistTaskExecutionRecords()
            return
        }
        guard sharedKernelRecordPersistenceTask == nil else { return }
        let elapsed = Date().timeIntervalSince(sharedKernelLastRecordPersistenceAt)
        let delay = max(0, 1.0 - elapsed)
        sharedKernelRecordPersistenceTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled else { return }
            self.sharedKernelRecordPersistenceTask = nil
            self.sharedKernelLastRecordPersistenceAt = Date()
            self.persistTaskExecutionRecords()
        }
    }

    private func ensureSharedKernelLegacyMemoryImported() async throws {
        guard !sharedKernelLegacyMemoryImported else { return }
        var entries: [LingShuKernelMemoryImportEntry] = []

        entries += memoryService.repository.loadMainThreadRecords().map { record in
            LingShuKernelMemoryImportEntry(
                id: "swift-main-\(record.id)",
                kind: .conversation,
                tier: .hot,
                title: record.title,
                content: Self.sharedKernelMemoryContent(record.summary, fallback: record.lastPrompt),
                lastPrompt: record.lastPrompt,
                tags: record.tags + [record.category],
                source: .legacySwift,
                importance: 0.55,
                confidence: 0.8,
                sensitive: false,
                messageCount: UInt32(clamping: record.messageCount),
                taskId: nil,
                executionRecordId: nil,
                createdAt: Self.sharedKernelISODate(record.createdAt),
                updatedAt: Self.sharedKernelISODate(record.updatedAt),
                archivedAt: nil,
                compressedAt: record.compressedAt.map(Self.sharedKernelISODate),
                aliases: []
            )
        }
        entries += memoryService.repository.loadTaskRecords().map { record in
            LingShuKernelMemoryImportEntry(
                id: "swift-task-\(record.id)",
                kind: .task,
                tier: .hot,
                title: record.title,
                content: Self.sharedKernelMemoryContent(record.summary, fallback: record.lastPrompt),
                lastPrompt: record.lastPrompt,
                tags: record.tags + [record.status],
                source: .legacySwift,
                importance: 0.7,
                confidence: 0.85,
                sensitive: false,
                messageCount: 1,
                taskId: record.id,
                executionRecordId: record.executionRecordID,
                createdAt: nil,
                updatedAt: Self.sharedKernelISODate(record.updatedAt),
                archivedAt: nil,
                compressedAt: nil,
                aliases: []
            )
        }
        entries += memoryService.repository.loadColdRecords().map { record in
            let classification = "\(record.source) \(record.category)".lowercased()
            let taskLike = classification.contains("task") || classification.contains("任务")
            return LingShuKernelMemoryImportEntry(
                id: "swift-cold-\(record.id)",
                kind: taskLike ? .task : .conversation,
                tier: .cold,
                title: record.title,
                content: Self.sharedKernelMemoryContent(record.summary, fallback: record.lastPrompt),
                lastPrompt: record.lastPrompt,
                tags: record.tags + [record.category, record.source],
                source: .legacySwift,
                importance: taskLike ? 0.65 : 0.45,
                confidence: 0.75,
                sensitive: false,
                messageCount: 1,
                taskId: taskLike ? record.id : nil,
                executionRecordId: nil,
                createdAt: nil,
                updatedAt: Self.sharedKernelISODate(record.updatedAt),
                archivedAt: Self.sharedKernelISODate(record.archivedAt),
                compressedAt: nil,
                aliases: []
            )
        }
        entries += memoryService.semanticStore.recentEntries(limit: 1_000).map { entry in
            LingShuKernelMemoryImportEntry(
                id: "swift-semantic-\(entry.id)",
                kind: Self.sharedKernelSemanticMemoryKind(entry.kind),
                tier: .hot,
                title: entry.title,
                content: entry.content,
                lastPrompt: "",
                tags: entry.tags,
                source: .legacySwift,
                importance: entry.importance,
                confidence: 0.8,
                sensitive: false,
                messageCount: 1,
                taskId: nil,
                executionRecordId: nil,
                createdAt: Self.sharedKernelISODate(entry.createdAt),
                updatedAt: Self.sharedKernelISODate(entry.updatedAt),
                archivedAt: nil,
                compressedAt: nil,
                aliases: []
            )
        }
        entries += knowledgeGraph.notes.map { note in
            LingShuKernelMemoryImportEntry(
                id: "swift-graph-\(note.id)",
                kind: Self.sharedKernelGraphMemoryKind(note.kind),
                tier: .hot,
                title: note.title,
                content: note.body,
                lastPrompt: "",
                tags: note.tags + note.links,
                source: .legacySwift,
                importance: note.source == .userExplicit ? 0.95 : 0.75,
                confidence: note.confidence,
                sensitive: note.sensitive,
                messageCount: 1,
                taskId: nil,
                executionRecordId: nil,
                createdAt: Self.sharedKernelISODate(note.created),
                updatedAt: Self.sharedKernelISODate(note.updated),
                archivedAt: nil,
                compressedAt: nil,
                aliases: note.aliases
            )
        }
        entries += recentDeliverables.map { deliverable in
            let path = deliverable.primaryDir.map { "Path: \($0)\n" } ?? ""
            return LingShuKernelMemoryImportEntry(
                id: "swift-deliverable-\(deliverable.id)",
                kind: .artifact,
                tier: .hot,
                title: deliverable.title,
                content: path + deliverable.summaryExcerpt,
                lastPrompt: "",
                tags: ["deliverable", "artifact"],
                source: .legacySwift,
                importance: 0.9,
                confidence: 0.95,
                sensitive: false,
                messageCount: 1,
                taskId: deliverable.id,
                executionRecordId: deliverable.id,
                createdAt: Self.sharedKernelISODate(deliverable.completedAt),
                updatedAt: Self.sharedKernelISODate(deliverable.completedAt),
                archivedAt: nil,
                compressedAt: nil,
                aliases: []
            )
        }

        let result = try await sharedKernelRuntime.importMemory(
            LingShuKernelMemoryImportPayload(
                source: "swift-memory",
                sourceVersion: "v1",
                entries: entries
            )
        )
        sharedKernelLegacyMemoryImported = true
        mainMemoryStatus = loc(
            "Rust 热记忆 \(result.snapshot.hotCount) 条",
            "Rust hot memory: \(result.snapshot.hotCount)"
        )
        coldMemoryStatus = loc(
            "Rust 冷记忆 \(result.snapshot.coldCount) 条",
            "Rust cold memory: \(result.snapshot.coldCount)"
        )
        appendTrace(
            kind: .runtime,
            actor: "MemoryKernel",
            title: loc("旧记忆迁移完成", "Legacy memory imported"),
            detail: "imported=\(result.imported) updated=\(result.updated) skipped=\(result.skipped)"
        )
    }

    private static func sharedKernelMemoryContent(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sharedKernelSemanticMemoryKind(_ value: String) -> LingShuKernelMemoryKind {
        let value = value.lowercased()
        if value.contains("preference") || value.contains("偏好") { return .preference }
        if value.contains("task") || value.contains("任务") { return .task }
        if value.contains("fact") || value.contains("事实") { return .fact }
        if value.contains("experience") || value.contains("经验") { return .experience }
        return .knowledge
    }

    private static func sharedKernelGraphMemoryKind(
        _ kind: LingShuMemoryNote.Kind
    ) -> LingShuKernelMemoryKind {
        switch kind {
        case .preference:
            .preference
        case .decision, .fact, .person:
            .fact
        case .project, .skill, .glossary:
            .knowledge
        }
    }

    private static func sharedKernelISODate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }


}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
