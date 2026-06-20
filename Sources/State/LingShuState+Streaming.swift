import Foundation

/// 流式回复的消费侧：经适配器归一化的（思考增量, 正文增量）如何驱动界面。
/// 思考增量滚动在加载气泡的推理预览区，正文增量进调用链或直接上屏。
@MainActor
extension LingShuState {
    /// 按当前主通道选择回复适配器（M3 内联 think / 标准模型直通）。
    var currentReplyAdapter: LingShuModelReplyAdapting {
        LingShuModelReplyAdapters.adapter(provider: modelProvider, model: modelName)
    }

    /// 守护/探活类 actor 的轨迹不上主时间线（appendTrace 据此抑制噪声）。
    func isGuardActor(_ actor: String) -> Bool {
        actor.contains("守护") || actor.contains("探活")
    }

    /// 轨迹/底层输出文本清洗：剥 ANSI 控制符、归一回车、超长截断。
    func cleanTraceText(_ rawText: String) -> String {
        let withoutControlCharacters = rawText
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard withoutControlCharacters.count > 420 else { return withoutControlCharacters }
        return String(withoutControlCharacters.prefix(420)) + "..."
    }

    /// 用户在选择卡片上点了某个选项：标记已解决，把 label 作为一条输入提交，交 agent 循环推进。
    func selectRouteChoice(_ option: CodexRouteChoiceOption, for messageID: UUID) {
        guard let index = chatMessages.firstIndex(where: { $0.id == messageID }),
              chatMessages[index].resolvedChoice == nil else { return }
        chatMessages[index].resolvedChoice = option.label
        // ask_choice:有在飞的循环挂起等点选 → 直接唤醒它继续(不另起新输入);否则走旧 route-choice 路径。
        if let resolver = pendingChoiceResolvers.removeValue(forKey: messageID) {
            resolver(option.label)
        } else {
            _ = submitTextInput(option.label, source: .typed)
        }
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

    /// 执行阶段的流式气泡：正文增量边到边追加上屏；语音输出开启时整句即到即读。
    func appendStreamingBubbleText(_ delta: String, to messageID: UUID?) {
        guard let messageID,
              let index = chatMessages.firstIndex(where: { $0.id == messageID }),
              chatMessages[index].isLoading else { return }
        chatMessages[index].text += delta
        emitCompletedStreamSentences(for: messageID, text: chatMessages[index].text)
    }

    /// 分句早读：流式正文每攒满一句（。！？；换行）立即交给注册的播报器，
    /// 语音对话不必等整段回复生成完——首句即开口。
    private func emitCompletedStreamSentences(for messageID: UUID, text: String) {
        guard let speaker = streamingSentenceSpeaker else { return }
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        let characters = Array(text)
        let offset = spokenStreamOffsets[messageID] ?? 0
        guard offset < characters.count else { return }

        var lastBoundary: Int?
        for index in offset..<characters.count where terminators.contains(characters[index]) {
            lastBoundary = index
        }
        guard let boundary = lastBoundary else { return }

        let sentence = String(characters[offset...boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        spokenStreamOffsets[messageID] = boundary + 1
        if sentence.count >= 2 {
            lingShuControlLog("流式早读句: 「\(sentence.prefix(12))」 id=\(messageID.uuidString.prefix(8))")
            speaker(sentence)
        }
    }

    /// 流式消息定稿时的语音收尾：早读过的消息补读尾句并打去重标记，
    /// 避免根视图把整段回复再念一遍；没早读过则不干预（保持原有整段播报）。
    func concludeStreamedSpeech(for messageID: UUID, streamedText: String) {
        guard let offset = spokenStreamOffsets.removeValue(forKey: messageID) else {
            lingShuControlLog("concludeStreamedSpeech: 无早读offset → 根视图会整段朗读 id=\(messageID.uuidString.prefix(8))")
            return
        }
        lingShuControlLog("concludeStreamedSpeech: 设去重标记 id=\(messageID.uuidString.prefix(8))")
        lastSpokenMessageID = messageID
        let characters = Array(streamedText)
        if offset < characters.count, let speaker = streamingSentenceSpeaker {
            let tail = String(characters[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.count >= 2 { speaker(tail) }
        }
        // 没有更多句子了 → 流式发声收口(drainer 播完剩余即 finishAndDrain)。
        voiceManager?.finishStreamingSpeech()
    }

    /// 定稿流式气泡：流式中的临时文本替换为验收后的最终回复。没有流式气泡
    /// （非流式模式）时退回旧行为——直接追加一条新消息。
    func finalizeStreamingBubble(_ messageID: UUID?, text: String, taskRecordID: String?) {
        if let messageID {
            clearThinkingPreview(for: messageID)
            if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                concludeStreamedSpeech(for: messageID, streamedText: chatMessages[index].text)
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
