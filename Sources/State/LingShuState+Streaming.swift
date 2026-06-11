import Foundation

/// 流式回复的消费侧：经适配器归一化的（思考增量, 正文增量）如何驱动界面。
/// 思考增量滚动在加载气泡的推理预览区，正文增量进调用链或直接上屏。
@MainActor
extension LingShuState {
    /// 按当前主通道选择回复适配器（M3 内联 think / 标准模型直通）。
    var currentReplyAdapter: LingShuModelReplyAdapting {
        LingShuModelReplyAdapters.adapter(provider: modelProvider, model: modelName)
    }

    /// 用户在选择卡片上点了某个选项：标记该卡片已解决，并把选项作为一条输入提交，推进对话。
    func selectRouteChoice(_ option: String, for messageID: UUID) {
        guard let index = chatMessages.firstIndex(where: { $0.id == messageID }),
              chatMessages[index].resolvedChoice == nil else { return }
        chatMessages[index].resolvedChoice = option
        _ = submitTextInput(option, source: .typed)
    }

    func recordRemoteStreamRetryDiagnostic(_ line: String, actor: String) {
        mainRemoteLastDiagnosticLog = line
        if mainRemoteConsecutiveFailures == 0 {
            mainRemoteConnectionStatus = LingShuRemoteConnectionPhase.degraded.rawValue
            mainRemoteConnectionDetail = "检测到流式断开，底层正在自动重试。"
        }
    }

    func recordModelHeartbeat(source: String, detail: String, isSynthetic: Bool = false) {
        lastModelHeartbeatAt = Date()
        modelHeartbeatIdleSeconds = 0
        modelHeartbeatSource = source
    }

    func appendModelStream(_ rawText: String, actor: String, title: String = "流式输出") {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map(cleanTraceText)
            .filter { !$0.isEmpty }

        for line in lines.prefix(12) {
            recordModelHeartbeat(source: actor, detail: line, isSynthetic: false)
            appendTrace(kind: .model, actor: actor, title: title, detail: line, isStream: true)
        }
    }

    /// 消费经适配器归一化后的流式事件：思考增量驱动气泡上的实时推理预览，
    /// 正文增量进调用链。模型方言（M3 内联 think 等）已在适配器层被抹平。
    func consumeModelStreamEvent(
        _ event: LingShuReplyStreamEvent,
        actor: String,
        thinkingMessageID: UUID?,
        contentSink: ((String) -> Void)? = nil
    ) {
        if !event.reasoningDelta.isEmpty {
            appendModelStream(event.reasoningDelta, actor: actor, title: "思考")
            if let thinkingMessageID {
                advanceThinkingPreview(event.reasoningDelta, for: thinkingMessageID)
            }
        }
        if !event.contentDelta.isEmpty {
            appendModelStream(event.contentDelta, actor: actor)
            contentSink?(event.contentDelta)
        }
    }

    /// 思考增量累积出气泡上的滚动预览：只展示最近一段，避免气泡无限增高。
    func advanceThinkingPreview(_ delta: String, for messageID: UUID) {
        thinkingPreviewBuffers[messageID, default: ""] += delta
        guard let index = chatMessages.firstIndex(where: { $0.id == messageID }),
              chatMessages[index].isLoading else { return }
        let buffer = thinkingPreviewBuffers[messageID] ?? ""
        let preview = String(buffer.suffix(220))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if chatMessages[index].thinkingPreview != preview {
            chatMessages[index].thinkingPreview = preview.isEmpty ? nil : preview
        }
    }

    /// 定稿一条消息时清掉思考预览；推理过程只留在调用链里，不进聊天历史。
    func clearThinkingPreview(for messageID: UUID) {
        thinkingPreviewBuffers.removeValue(forKey: messageID)
        if let index = chatMessages.firstIndex(where: { $0.id == messageID }),
           chatMessages[index].thinkingPreview != nil {
            chatMessages[index].thinkingPreview = nil
        }
    }

    /// 执行阶段的流式气泡：正文增量边到边追加上屏。
    func appendStreamingBubbleText(_ delta: String, to messageID: UUID?) {
        guard let messageID,
              let index = chatMessages.firstIndex(where: { $0.id == messageID }),
              chatMessages[index].isLoading else { return }
        chatMessages[index].text += delta
    }

    /// 定稿流式气泡：流式中的临时文本替换为验收后的最终回复。没有流式气泡
    /// （非流式模式）时退回旧行为——直接追加一条新消息。
    func finalizeStreamingBubble(_ messageID: UUID?, text: String, taskRecordID: String?) {
        if let messageID {
            clearThinkingPreview(for: messageID)
            if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                if text.isEmpty {
                    chatMessages.remove(at: index)
                } else {
                    chatMessages[index].text = text
                    chatMessages[index].isLoading = false
                    chatMessages[index].taskRecordID = taskRecordID
                }
                return
            }
        }
        guard !text.isEmpty else { return }
        chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false, taskRecordID: taskRecordID))
    }
}
