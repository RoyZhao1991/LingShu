import Foundation

enum LingShuSpeechIntentDecision: Equatable {
    case speak
    case silent
    case unspecified
}

/// Whether a single user turn asks for audible output.
///
/// TTS is a presentation choice, not a side effect of producing an assistant
/// message. Keep ordinary analysis and delivery work silent unless the user is
/// speaking to Nous or explicitly asks for narration, conversation, or a live
/// presentation.
enum LingShuSpeechIntentPolicy {
    nonisolated static func decision(
        for request: String,
        source: LingShuDialogueInputSource
    ) -> LingShuSpeechIntentDecision {
        let value = request
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if containsAny(value, [
            "不要读出声", "不要朗读", "不要播报", "不要语音", "别出声", "保持静音",
            "只要文字", "文字回复", "静默回复",
            "do not speak", "don't speak", "do not read aloud", "don't read aloud",
            "no voice", "text only", "reply in text", "stay silent"
        ]) {
            return .silent
        }

        switch source {
        case .voice, .meeting:
            return .speak
        case .typed, .plugin:
            break
        }

        if containsAny(value, [
            "读出声", "朗读", "念给我听", "读给我听", "说给我听", "讲给我听",
            "播报", "口头汇报", "口头讲解", "语音回复", "用语音回答", "用声音回答",
            "和我对话", "跟我对话", "进行对话", "和我聊", "跟我聊", "聊一聊", "聊聊",
            "和我沟通", "跟我沟通", "沟通一下", "语音沟通",
            "开始演示", "为我演示", "给我演示", "帮我演示", "演示一下",
            "演示这个", "演示这份", "演示该", "现场演示",
            "演讲一下", "开始放映", "边演示边讲",
            "read aloud", "read it aloud", "read it to me", "say it aloud", "speak your answer",
            "answer out loud", "answer by voice", "voice reply", "voice response",
            "talk to me", "chat with me", "have a conversation", "communicate with me",
            "walk me through", "present it", "present this", "present the ",
            "start the presentation", "give a presentation", "demo this", "narrate"
        ]) {
            return .speak
        }

        return .unspecified
    }

    private nonisolated static func containsAny(_ value: String, _ signals: [String]) -> Bool {
        signals.contains { value.contains($0) }
    }
}
