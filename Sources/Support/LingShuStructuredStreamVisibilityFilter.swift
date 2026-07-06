import Foundation

struct LingShuStructuredStreamVisibilityResult: Sendable, Equatable {
    var visibleDelta: String
    var hiddenDelta: String
    var shouldClearVisibleText: Bool

    static let empty = LingShuStructuredStreamVisibilityResult(
        visibleDelta: "",
        hiddenDelta: "",
        shouldClearVisibleText: false
    )
}

/// Filters model-stream deltas before they reach the user-visible chat bubble.
///
/// The final-answer contract asks the brain to return a whole JSON object so the
/// harness can read control fields. Raw streaming deltas arrive before that JSON
/// can be parsed, so JSON-shaped output must stay hidden until finalization
/// replaces the bubble with `reply`.
struct LingShuStructuredStreamVisibilityFilter: Sendable, Equatable {
    private static let protocolDetectionWindow = 120

    private enum Mode: Sendable, Equatable {
        case undecided
        case visible
        case hiddenStructuredObject
    }

    private var mode: Mode = .undecided
    private var bufferedPrefix = ""
    private var visibleTail = ""

    mutating func consume(_ delta: String) -> String {
        consumeWithMetadata(delta).visibleDelta
    }

    mutating func consumeWithMetadata(_ delta: String) -> LingShuStructuredStreamVisibilityResult {
        guard !delta.isEmpty else { return .empty }
        switch mode {
        case .visible:
            let probe = visibleTail + delta
            if Self.containsStructuredProtocolStart(probe) {
                mode = .hiddenStructuredObject
                bufferedPrefix.removeAll(keepingCapacity: true)
                visibleTail.removeAll(keepingCapacity: true)
                return .init(visibleDelta: "", hiddenDelta: delta, shouldClearVisibleText: true)
            }
            rememberVisibleTail(delta)
            return .init(visibleDelta: delta, hiddenDelta: "", shouldClearVisibleText: false)
        case .hiddenStructuredObject:
            return .init(visibleDelta: "", hiddenDelta: delta, shouldClearVisibleText: false)
        case .undecided:
            bufferedPrefix += delta
            return decideFromBufferedPrefix()
        }
    }

    private mutating func decideFromBufferedPrefix() -> LingShuStructuredStreamVisibilityResult {
        let trimmed = bufferedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .init(visibleDelta: "", hiddenDelta: bufferedPrefix, shouldClearVisibleText: false)
        }

        if trimmed.hasPrefix("{") {
            mode = .hiddenStructuredObject
            let hidden = bufferedPrefix
            bufferedPrefix.removeAll(keepingCapacity: true)
            return .init(visibleDelta: "", hiddenDelta: hidden, shouldClearVisibleText: false)
        }

        if trimmed.hasPrefix("```") {
            return decideForFence(trimmed)
        }

        if Self.containsStructuredProtocolStart(bufferedPrefix) {
            mode = .hiddenStructuredObject
            let hidden = bufferedPrefix
            bufferedPrefix.removeAll(keepingCapacity: true)
            return .init(visibleDelta: "", hiddenDelta: hidden, shouldClearVisibleText: false)
        }

        // 给结构化回复留一个短暂判定窗口。若模型稍后才吐 JSON 协议块，
        // 上层会清掉已露出的临时文本；短答则定稿时一次性写入正文。
        guard bufferedPrefix.count >= Self.protocolDetectionWindow else {
            return .init(visibleDelta: "", hiddenDelta: bufferedPrefix, shouldClearVisibleText: false)
        }

        return releaseBufferedPrefix()
    }

    private mutating func decideForFence(_ trimmed: String) -> LingShuStructuredStreamVisibilityResult {
        let lower = trimmed.lowercased()
        let firstLine = lower.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? lower

        if firstLine == "```json" || firstLine == "``` json" {
            mode = .hiddenStructuredObject
            let hidden = bufferedPrefix
            bufferedPrefix.removeAll(keepingCapacity: true)
            return .init(visibleDelta: "", hiddenDelta: hidden, shouldClearVisibleText: false)
        }

        guard trimmed.contains("\n") else {
            return .init(visibleDelta: "", hiddenDelta: bufferedPrefix, shouldClearVisibleText: false)
        }
        let body = trimmed.components(separatedBy: .newlines).dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{") {
            mode = .hiddenStructuredObject
            let hidden = bufferedPrefix
            bufferedPrefix.removeAll(keepingCapacity: true)
            return .init(visibleDelta: "", hiddenDelta: hidden, shouldClearVisibleText: false)
        }

        return releaseBufferedPrefix()
    }

    private mutating func releaseBufferedPrefix() -> LingShuStructuredStreamVisibilityResult {
        mode = .visible
        let output = bufferedPrefix
        rememberVisibleTail(output)
        bufferedPrefix.removeAll(keepingCapacity: true)
        return .init(visibleDelta: output, hiddenDelta: "", shouldClearVisibleText: false)
    }

    private mutating func rememberVisibleTail(_ delta: String) {
        visibleTail = String((visibleTail + delta).suffix(260))
    }

    private static func containsStructuredProtocolStart(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("```json") || lower.contains("``` json") { return true }
        guard let brace = lower.firstIndex(of: "{") else { return false }
        let suffix = String(lower[brace...].prefix(360))
        let protocolKeys = [
            "\"reply\"",
            "\"message\"",
            "\"completion\"",
            "\"user_input\"",
            "\"userinput\"",
            "\"inability\"",
            "\"oauth\""
        ]
        return protocolKeys.contains { suffix.contains($0) }
    }
}
