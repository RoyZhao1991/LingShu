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
}

struct LingShuPendingHumanInputContext {
    var recordID: String?
    var originalPrompt: String
}
