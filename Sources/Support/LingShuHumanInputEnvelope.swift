import Foundation

/// Human-in-the-loop tool calls must release the agent loop instead of waiting
/// inside the tool handler. The loop returns `.blocked` with this envelope, the
/// UI renders the matching card, and user input later resumes the original
/// tool call.
struct LingShuHumanInputEnvelope: Codable, Equatable, Sendable {
    static let prefix = "__LINGSHU_HUMAN_INPUT__:"
    static let blockingToolNames: Set<String> = ["ask_user", "ask_choice", "ask_form"]

    var tool: String
    var argumentsJSON: String

    var encodedPrompt: String {
        guard let data = try? JSONEncoder().encode(self) else { return argumentsJSON }
        return Self.prefix + data.base64EncodedString()
    }

    static func decode(from prompt: String) -> LingShuHumanInputEnvelope? {
        guard prompt.hasPrefix(prefix) else { return nil }
        let raw = String(prompt.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: raw) else { return nil }
        return try? JSONDecoder().decode(LingShuHumanInputEnvelope.self, from: data)
    }

    /// 把内部 human-in-the-loop 信封转成人能读的文字。信封是 agent loop 的协议细节,
    /// 任何用户可见气泡/任务摘要都不能裸露 base64 payload。
    static func userFacingText(from text: String) -> String {
        var output = text
        while let hit = firstEmbedded(in: output) {
            output.replaceSubrange(hit.range, with: userFacingText(for: hit.envelope))
        }
        return output
    }

    static func userFacingText(for envelope: LingShuHumanInputEnvelope) -> String {
        let args = jsonObject(envelope.argumentsJSON)
        switch envelope.tool {
        case "ask_form":
            return firstString(in: args, keys: ["title", "question", "prompt", "message"])
                ?? "我需要你确认几件事。"
        case "ask_choice":
            return firstString(in: args, keys: ["question", "title", "prompt", "message"])
                ?? "我需要你做个选择。"
        default:
            return firstString(in: args, keys: ["question", "prompt", "message", "title"])
                ?? "我需要你先定一下。"
        }
    }

    static func firstEmbedded(in text: String) -> (range: Range<String.Index>, envelope: LingShuHumanInputEnvelope)? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        var end = prefixRange.upperBound
        while end < text.endIndex, isBase64Scalar(text[end]) {
            end = text.index(after: end)
        }
        guard prefixRange.upperBound < end else { return nil }
        let tokenRange = prefixRange.lowerBound..<end
        let token = String(text[tokenRange])
        guard let envelope = decode(from: token) else { return nil }
        return (tokenRange, envelope)
    }

    private static func isBase64Scalar(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 48...57, 65...90, 97...122: return true
        case 43, 47, 61: return true
        default: return false
        }
    }

    private static func jsonObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func firstString(in obj: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = obj[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

struct LingShuPendingHumanInputContext {
    var recordID: String?
    var originalPrompt: String
}
