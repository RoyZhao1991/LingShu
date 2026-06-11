import Foundation

enum LingShuPerceptionAwarenessLevel: String, Codable, Equatable, Sendable {
    case idle
    case observing
    case contextual
    case attention
    case critical

    var label: String {
        switch self {
        case .idle: "待机"
        case .observing: "观察"
        case .contextual: "上下文增强"
        case .attention: "注意"
        case .critical: "关键变化"
        }
    }

    var priority: Int {
        switch self {
        case .idle: 0
        case .observing: 1
        case .contextual: 2
        case .attention: 3
        case .critical: 4
        }
    }

    static func max(_ lhs: LingShuPerceptionAwarenessLevel, _ rhs: LingShuPerceptionAwarenessLevel) -> LingShuPerceptionAwarenessLevel {
        lhs.priority >= rhs.priority ? lhs : rhs
    }
}

enum LingShuPerceptionThreadAction: String, Codable, Equatable, Sendable {
    case observeOnly
    case enrichNextReply
    case askForConfirmation
    case interruptWithSuggestion

    var label: String {
        switch self {
        case .observeOnly: "只观察"
        case .enrichNextReply: "增强下次回复"
        case .askForConfirmation: "先确认"
        case .interruptWithSuggestion: "主动提醒"
        }
    }
}

struct LingShuSpeakerIdentityCandidate: Codable, Equatable, Sendable {
    var displayName: String
    var confidence: Double
    var source: String
    var updatedAt: Date

    var isVerified: Bool {
        confidence >= 0.75 && !displayName.contains("待确认")
    }

    static func unknown(source: String, updatedAt: Date) -> LingShuSpeakerIdentityCandidate {
        LingShuSpeakerIdentityCandidate(
            displayName: "说话人待确认",
            confidence: 0,
            source: source,
            updatedAt: updatedAt
        )
    }
}

struct LingShuPerceptionSituationSnapshot: Codable, Equatable, Sendable {
    var timestamp: Date
    var level: LingShuPerceptionAwarenessLevel
    var speaker: LingShuSpeakerIdentityCandidate?
    var visualSummary: String
    var audioSummary: String
    var modelSummary: String
    var recommendedAction: String
    var action: LingShuPerceptionThreadAction
    var shouldInterrupt: Bool
    var promptContext: String

    static let idle = LingShuPerceptionSituationSnapshot(
        timestamp: Date(timeIntervalSince1970: 0),
        level: .idle,
        speaker: nil,
        visualSummary: "",
        audioSummary: "",
        modelSummary: "",
        recommendedAction: "保持待机，不干扰主对话。",
        action: .observeOnly,
        shouldInterrupt: false,
        promptContext: "感知线程：暂无有效感知信号。"
    )
}

struct LingShuPerceptionThreadCoordinator {
    func makeSnapshot(
        transcription: LingShuVoiceTranscriptionResult?,
        vision: LingShuVisionObservation?,
        modelReply: LingShuRealtimePerceptionModelReply?,
        now: Date = Date()
    ) -> LingShuPerceptionSituationSnapshot {
        let timestamp = latestTimestamp(
            transcription: transcription,
            vision: vision,
            modelReply: modelReply,
            fallback: now
        )
        let speaker = speakerCandidate(
            transcription: transcription,
            modelReply: modelReply,
            timestamp: timestamp
        )
        let audioSummary = makeAudioSummary(transcription)
        let visualSummary = makeVisualSummary(vision)
        let modelSummary = modelReply?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let level = makeLevel(
            transcription: transcription,
            vision: vision,
            modelReply: modelReply
        )
        let action = makeAction(level: level, speaker: speaker, vision: vision)
        let recommendedAction = makeRecommendedAction(
            level: level,
            action: action,
            speaker: speaker,
            modelReply: modelReply
        )
        let shouldInterrupt = action == .interruptWithSuggestion
        let promptContext = makePromptContext(
            level: level,
            speaker: speaker,
            audioSummary: audioSummary,
            visualSummary: visualSummary,
            modelSummary: modelSummary,
            recommendedAction: recommendedAction
        )

        return LingShuPerceptionSituationSnapshot(
            timestamp: timestamp,
            level: level,
            speaker: speaker,
            visualSummary: visualSummary,
            audioSummary: audioSummary,
            modelSummary: modelSummary,
            recommendedAction: recommendedAction,
            action: action,
            shouldInterrupt: shouldInterrupt,
            promptContext: promptContext
        )
    }

    private func latestTimestamp(
        transcription: LingShuVoiceTranscriptionResult?,
        vision: LingShuVisionObservation?,
        modelReply: LingShuRealtimePerceptionModelReply?,
        fallback: Date
    ) -> Date {
        var dates = [fallback]
        if let transcription {
            dates.append(transcription.timestamp)
        }
        if let vision {
            dates.append(vision.timestamp)
        }
        if modelReply != nil {
            dates.append(fallback)
        }

        return dates.max() ?? fallback
    }

    private func speakerCandidate(
        transcription: LingShuVoiceTranscriptionResult?,
        modelReply: LingShuRealtimePerceptionModelReply?,
        timestamp: Date
    ) -> LingShuSpeakerIdentityCandidate? {
        let metadata = modelReply?.metadata ?? [:]
        let speakerName = firstMetadataValue(
            in: metadata,
            keys: ["speakerName", "speaker", "speaker_id", "speakerID"]
        )
        let speakerConfidence = doubleMetadataValue(
            in: metadata,
            keys: ["speakerConfidence", "speaker_confidence", "speakerScore", "speaker_score"]
        ) ?? 0

        if let speakerName, !speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LingShuSpeakerIdentityCandidate(
                displayName: speakerName,
                confidence: min(max(speakerConfidence, 0), 1),
                source: modelReply?.metadata?["speakerSource"] ?? "实时感知模型",
                updatedAt: timestamp
            )
        }

        guard let transcription else { return nil }
        return .unknown(source: transcription.provider.displayName, updatedAt: transcription.timestamp)
    }

    private func makeAudioSummary(_ transcription: LingShuVoiceTranscriptionResult?) -> String {
        guard let transcription else { return "" }
        let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let finalText = transcription.isFinal ? "最终转写" : "流式转写"
        if let confidence = transcription.confidence {
            return "\(finalText)：\(text)（置信度 \(percent(confidence))）"
        }

        return "\(finalText)：\(text)"
    }

    private func makeVisualSummary(_ vision: LingShuVisionObservation?) -> String {
        guard let vision else { return "" }

        var parts = [vision.summary]
        if vision.faceCount > 0 {
            parts.append("画面人数：\(vision.faceCount)")
        }
        if !vision.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("画面文字：\(vision.recognizedText)")
        }
        parts.append("亮度 \(String(format: "%.2f", vision.brightness))")
        parts.append("变化 \(String(format: "%.2f", vision.motion))")

        return parts.joined(separator: "；")
    }

    private func makeLevel(
        transcription: LingShuVoiceTranscriptionResult?,
        vision: LingShuVisionObservation?,
        modelReply: LingShuRealtimePerceptionModelReply?
    ) -> LingShuPerceptionAwarenessLevel {
        var level: LingShuPerceptionAwarenessLevel = .idle

        if transcription != nil || vision != nil || modelReply != nil {
            level = .observing
        }
        if let transcription,
           !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            level = .max(level, .contextual)
        }
        if let vision {
            level = .max(level, .contextual)
            if vision.faceCount > 1 || vision.motion >= 0.18 {
                level = .max(level, .attention)
            }
            if vision.recognizedText.localizedCaseInsensitiveContains("密码")
                || vision.recognizedText.localizedCaseInsensitiveContains("验证码") {
                level = .max(level, .attention)
            }
        }

        let modelLevel = modelReply?.metadata.flatMap {
            firstMetadataValue(in: $0, keys: ["situationLevel", "awarenessLevel", "riskLevel", "level"])
        }?.lowercased()

        switch modelLevel {
        case "critical", "risk", "danger", "high":
            level = .max(level, .critical)
        case "attention", "warning", "medium":
            level = .max(level, .attention)
        case "contextual", "context", "low":
            level = .max(level, .contextual)
        default:
            break
        }

        return level
    }

    private func makeAction(
        level: LingShuPerceptionAwarenessLevel,
        speaker: LingShuSpeakerIdentityCandidate?,
        vision: LingShuVisionObservation?
    ) -> LingShuPerceptionThreadAction {
        switch level {
        case .idle:
            return .observeOnly
        case .observing, .contextual:
            return .enrichNextReply
        case .attention:
            if speaker?.isVerified == false || (vision?.faceCount ?? 0) > 1 {
                return .askForConfirmation
            }
            return .enrichNextReply
        case .critical:
            return .interruptWithSuggestion
        }
    }

    private func makeRecommendedAction(
        level: LingShuPerceptionAwarenessLevel,
        action: LingShuPerceptionThreadAction,
        speaker: LingShuSpeakerIdentityCandidate?,
        modelReply: LingShuRealtimePerceptionModelReply?
    ) -> String {
        if let explicitAction = modelReply?.metadata.flatMap({
            firstMetadataValue(in: $0, keys: ["recommendedAction", "suggestion", "nextAction"])
        }),
           !explicitAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitAction
        }

        switch action {
        case .observeOnly:
            return "保持待机，不干扰主对话。"
        case .enrichNextReply:
            return "把感知快照作为主线程下一次判断的上下文。"
        case .askForConfirmation:
            if speaker?.isVerified == false {
                return "涉及身份、权限或隐私时先确认说话人，再继续执行。"
            }
            return "感知到环境变化，先确认用户意图是否仍然有效。"
        case .interruptWithSuggestion:
            return "出现关键态势变化，灵枢应中断等待并主动提醒用户确认。"
        }
    }

    private func makePromptContext(
        level: LingShuPerceptionAwarenessLevel,
        speaker: LingShuSpeakerIdentityCandidate?,
        audioSummary: String,
        visualSummary: String,
        modelSummary: String,
        recommendedAction: String
    ) -> String {
        guard level != .idle else {
            return "感知线程：暂无有效感知信号。"
        }

        var parts = ["感知线程快照：\(level.label)"]
        if let speaker {
            parts.append("说话人：\(speaker.displayName)，置信度 \(percent(speaker.confidence))，来源 \(speaker.source)。")
        }
        if !audioSummary.isEmpty {
            parts.append(audioSummary)
        }
        if !visualSummary.isEmpty {
            parts.append("视觉态势：\(visualSummary)")
        }
        if !modelSummary.isEmpty {
            parts.append("模型感知：\(modelSummary)")
        }
        parts.append("建议：\(recommendedAction)")

        return parts.joined(separator: "\n")
    }

    private func firstMetadataValue(in metadata: [String: String], keys: [String]) -> String? {
        keys.lazy.compactMap { key in
            metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
    }

    private func doubleMetadataValue(in metadata: [String: String], keys: [String]) -> Double? {
        guard let value = firstMetadataValue(in: metadata, keys: keys) else { return nil }
        return Double(value.replacingOccurrences(of: "%", with: "")).map {
            value.contains("%") ? $0 / 100 : $0
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }
}
