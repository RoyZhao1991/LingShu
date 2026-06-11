import Foundation

/// 升级标记门：直答流式正文先攒前几个字符，确认开头不是「【任务】」标记后才放行上屏。
/// 命中标记说明本地分类误判（其实是交付型任务），宿主切回完整路由编排。
struct LingShuTaskEscapeGate {
    enum Output: Equatable {
        case buffering
        case escalate
        case release(String)
    }

    private let marker: String
    private var buffer = ""
    private var released = false

    init(marker: String) {
        self.marker = marker
    }

    mutating func consume(_ delta: String) -> Output {
        if released {
            return .release(delta)
        }
        buffer += delta
        let trimmed = String(buffer.drop(while: { $0.isWhitespace || $0.isNewline }))
        if trimmed.count >= marker.count {
            if trimmed.hasPrefix(marker) {
                return .escalate
            }
            released = true
            return .release(buffer)
        }
        // 已经能确定不是标记前缀：提前放行，避免多攒一拍。
        if !trimmed.isEmpty && !marker.hasPrefix(trimmed) {
            released = true
            return .release(buffer)
        }
        return .buffering
    }

    /// 流结束仍在缓冲（极短回复）：剩余内容是标记或标记的残缺前缀都返回 nil（升级）——
    /// 模型显然想打标记但流被截断；其余原样放行。
    mutating func flush() -> String? {
        guard !released else { return "" }
        released = true
        let trimmed = String(buffer.drop(while: { $0.isWhitespace || $0.isNewline }))
        if !trimmed.isEmpty && (trimmed.hasPrefix(marker) || marker.hasPrefix(trimmed)) {
            return nil
        }
        return buffer
    }
}

/// 流式延迟探针：记录首增量/首正文/完成三个时点，结果进调用链——
/// 体验快不快由真实数字说话。
struct LingShuStreamLatencyProbe {
    let startedAt = Date()
    private(set) var firstDeltaAt: Date?
    private(set) var firstContentAt: Date?

    mutating func observeDelta(hasContent: Bool) {
        let now = Date()
        if firstDeltaAt == nil {
            firstDeltaAt = now
        }
        if hasContent && firstContentAt == nil {
            firstContentAt = now
        }
    }

    func summary() -> String {
        let total = Date().timeIntervalSince(startedAt)
        var parts: [String] = []
        if let firstDeltaAt {
            parts.append(String(format: "首响 %.1fs", firstDeltaAt.timeIntervalSince(startedAt)))
        }
        if let firstContentAt {
            parts.append(String(format: "首正文 %.1fs", firstContentAt.timeIntervalSince(startedAt)))
        }
        parts.append(String(format: "完成 %.1fs", total))
        return parts.joined(separator: " · ")
    }
}

/// 直答快路：本地分类判定为普通对话的消息不再走"路由 JSON"包装，
/// 直接以灵枢人格流式作答（实测 MiniMax M3 首正文 ~1.6s，路由路径为 ~4.5s，
/// 且答案要等完整 JSON 才能展示 ~8.9s）。模型若发现这其实是交付型任务，
/// 会以「【任务】」开头回复，宿主立即切回完整调度流程。
@MainActor
extension LingShuState {
    static let directChatTaskEscapeMarker = "【任务】"

    /// concurrent = true 表示"后台任务执行期间的并发闲聊"：不动 isModelReplying/
    /// 核心状态机，任务句柄独立存放，完成后走轻量收尾——执行管线完全不受影响。
    func requestDirectChatReply(
        for userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        replacing messageID: UUID,
        taskRecordID: String?,
        concurrent: Bool = false
    ) {
        if !concurrent {
            isModelReplying = true
        }
        let provider = modelProvider
        let model = modelName
        let endpoint = endpoint
        let apiKey = apiKey
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let timeout = codexTimeoutSeconds
        let memoryPromptHint = composedPromptHint(baseMemory: memoryContext.promptHint)
        let permission = permissionDecision(for: userPrompt)
        let chatSystemPrompt = routePlanner.chatSystemPrompt(permission: permission)
        let chatUserPrompt = routePlanner.routeUserPrompt(userPrompt: userPrompt, memoryContext: memoryPromptHint)
        let conversationMessages = modelConversationMessages(
            finalUserPrompt: chatUserPrompt,
            excludingCurrentRawPrompt: userPrompt
        )
        let useStreamingDialogue = shouldUseLocalStreamingDialogue
        let chatLease = remoteSessionPool.lease(
            provider: provider,
            model: model,
            purpose: .mainRouting,
            contextKey: mainThreadKernel.snapshot.sessionID,
            workingDirectory: codexWorkingDirectory,
            permissionBoundary: mainRoutingPermissionBoundary,
            endpoint: endpoint,
            protocolName: protocolName,
            localContextSummary: memoryPromptHint
        )
        let runID = missionRunID
        refreshRemoteSessionStatus()
        recordModelHeartbeat(source: "直答通道", detail: "\(provider) 直答请求已启动。")
        appendTrace(
            kind: .route,
            actor: "直答通道",
            title: concurrent ? "并发直答" : "快路直答",
            detail: "本地判定为普通对话，跳过路由编排，由 \(provider) / \(model) 直接流式作答。"
        )
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .router, text: "本地判断这是普通对话，我直接回答（未创建能力节点任务）。")

        let concurrentTaskKey = "direct-chat-\(messageID.uuidString)"
        // 并发模式下 missionRunID 可能被前台流程推进，不能作为失效判据。
        let isStale: @MainActor () -> Bool = { [weak self] in
            guard let self else { return true }
            return concurrent ? false : self.missionRunID != runID
        }
        let chatTask = Task { [weak self] in
            guard let self else { return }
            var probe = LingShuStreamLatencyProbe()
            do {
                let request = LingShuRemoteModelRequest(
                    provider: provider,
                    model: model,
                    endpoint: endpoint,
                    protocolName: protocolName,
                    apiKey: apiKey,
                    systemPrompt: chatSystemPrompt,
                    userPrompt: chatUserPrompt,
                    temperature: self.temperature,
                    stream: useStreamingDialogue,
                    timeout: timeout,
                    continuationToken: chatLease.continuationToken,
                    conversationMessages: conversationMessages
                )

                let reply: LingShuRemoteModelReply
                if useStreamingDialogue {
                    let streamParser = self.currentReplyAdapter.makeStreamParser()
                    var escapeGate = LingShuTaskEscapeGate(marker: Self.directChatTaskEscapeMarker)
                    var escalated = false
                    reply = try await self.remoteModelClient.stream(request) { [weak self] delta in
                        Task { @MainActor in
                            guard let self, !isStale(), !escalated else { return }
                            let event = streamParser.ingest(delta)
                            probe.observeDelta(hasContent: !event.contentDelta.isEmpty)
                            self.consumeModelStreamEvent(
                                event,
                                actor: "直答通道",
                                thinkingMessageID: messageID
                            ) { content in
                                switch escapeGate.consume(content) {
                                case .buffering:
                                    break
                                case .escalate:
                                    escalated = true
                                    self.escalateDirectChatToTaskFlow(
                                        userPrompt: userPrompt,
                                        memoryContext: memoryContext,
                                        messageID: messageID,
                                        taskRecordID: taskRecordID,
                                        concurrentTaskKey: concurrent ? concurrentTaskKey : nil
                                    )
                                case .release(let text):
                                    self.appendStreamingBubbleText(text, to: messageID)
                                }
                            }
                        }
                    } onHeartbeat: { [weak self] in
                        Task { @MainActor in
                            guard let self, !isStale() else { return }
                            self.recordModelHeartbeat(source: "直答通道", detail: "流式连接活跃。")
                        }
                    }
                    guard !escalated, !Task.isCancelled, !isStale() else { return }
                    let tailEvent = streamParser.finish()
                    if !tailEvent.contentDelta.isEmpty || !tailEvent.reasoningDelta.isEmpty {
                        self.consumeModelStreamEvent(tailEvent, actor: "直答通道", thinkingMessageID: messageID) { content in
                            if case .release(let text) = escapeGate.consume(content) {
                                self.appendStreamingBubbleText(text, to: messageID)
                            }
                        }
                    }
                    if escapeGate.flush() == nil {
                        self.escalateDirectChatToTaskFlow(
                            userPrompt: userPrompt,
                            memoryContext: memoryContext,
                            messageID: messageID,
                            taskRecordID: taskRecordID,
                            concurrentTaskKey: concurrent ? concurrentTaskKey : nil
                        )
                        return
                    }
                } else {
                    reply = try await self.remoteModelClient.send(request)
                    probe.observeDelta(hasContent: true)
                }

                guard !Task.isCancelled, !isStale() else { return }
                self.recordModelUsage(reply, stage: "直答")
                let finalText = self.currentReplyAdapter.normalizedReplyText(reply.text)

                // 非流式或被适配器剥离后才暴露的标记：仍然走升级。
                if finalText.hasPrefix(Self.directChatTaskEscapeMarker) {
                    self.escalateDirectChatToTaskFlow(
                        userPrompt: userPrompt,
                        memoryContext: memoryContext,
                        messageID: messageID,
                        taskRecordID: taskRecordID,
                        concurrentTaskKey: concurrent ? concurrentTaskKey : nil
                    )
                    return
                }

                self.remoteSessionPool.resolveNativeSession(
                    lease: chatLease,
                    nativeSessionID: nil,
                    continuationToken: reply.continuationToken,
                    localContextSummary: finalText
                )
                self.appendTrace(kind: .system, actor: "直答通道", title: "本轮延迟", detail: probe.summary())

                if concurrent {
                    // 并发闲聊轻量收尾：不碰核心状态机（后台管线还在跑）。
                    self.backgroundAPITasks.removeValue(forKey: concurrentTaskKey)
                    self.rememberMainThreadTurn(prompt: userPrompt, reply: finalText, route: nil)
                    self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                    self.finishTaskRecord(taskRecordID, status: .answered, summary: "执行期并发直答，未打断后台任务。")
                    self.finalizeStreamingBubble(messageID, text: finalText, taskRecordID: taskRecordID)
                    return
                }

                // 复用路由收尾：记忆写入、任务记录、内核观测、气泡定稿全部走同一条路。
                let payload = CodexRoutePayload(
                    needsAgents: false,
                    agents: [],
                    directAnswer: finalText,
                    finalAnswer: finalText,
                    summary: "直答快路：普通对话由灵枢直接回答。"
                )
                self.handleRouteResult(
                    payload,
                    userPrompt: userPrompt,
                    messageID: messageID,
                    taskRecordID: taskRecordID,
                    sourceLabel: "直答通道"
                )
            } catch {
                guard !Task.isCancelled, !isStale() else { return }
                let message = self.routePlanner.modelGatewayErrorMessage(error)
                self.remoteSessionPool.markFailed(lease: chatLease)
                self.refreshRemoteSessionStatus()
                if concurrent {
                    self.backgroundAPITasks.removeValue(forKey: concurrentTaskKey)
                } else {
                    self.activeAPITask = nil
                    self.isModelReplying = false
                    self.enterCoreState(.abnormal)
                }
                let finalText = "主通道刚才没有稳定响应。你可以稍后再发一次，或者去配置页检查模型配置。"
                self.appendTrace(kind: .warning, actor: "直答通道", title: "直答失败", detail: message)
                self.appendTaskRecordMessage(taskRecordID, actor: "直答通道", role: "主通道", kind: .warning, text: message)
                self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                self.finishTaskRecord(taskRecordID, status: .blocked, summary: finalText)
                self.finalizeStreamingBubble(messageID, text: finalText, taskRecordID: taskRecordID)
            }
        }
        if concurrent {
            backgroundAPITasks[concurrentTaskKey] = chatTask
        } else {
            activeAPITask = chatTask
        }
    }

    /// 直答模型识别到交付型诉求（或本地误判）：取消直答流，切回完整路由编排。
    /// 气泡保持加载态，由路由流程接手定稿。
    func escalateDirectChatToTaskFlow(
        userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        messageID: UUID,
        taskRecordID: String?,
        concurrentTaskKey: String? = nil
    ) {
        appendTrace(
            kind: .route,
            actor: "直答通道",
            title: "升级为任务流程",
            detail: "直答模型识别到这是交付型诉求，转入完整路由编排。"
        )
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .router, text: "这件事需要完整任务编排，我已切换到调度流程。")
        if let concurrentTaskKey {
            backgroundAPITasks[concurrentTaskKey]?.cancel()
            backgroundAPITasks.removeValue(forKey: concurrentTaskKey)
        } else {
            activeAPITask?.cancel()
            activeAPITask = nil
        }
        clearThinkingPreview(for: messageID)
        spokenStreamOffsets.removeValue(forKey: messageID)
        requestAPIGatewayRouteReply(
            for: userPrompt,
            memoryContext: memoryContext,
            replacing: messageID,
            taskRecordID: taskRecordID
        )
    }
}
