import Foundation

/// Filters model-stream deltas before they reach the user-visible chat bubble.
///
/// The final-answer contract asks the brain to return a whole JSON object so the
/// harness can read control fields. Raw streaming deltas arrive before that JSON
/// can be parsed, so JSON-shaped output must stay hidden until finalization
/// replaces the bubble with `reply`.
struct LingShuStructuredStreamVisibilityFilter: Sendable, Equatable {
    private enum Mode: Sendable, Equatable {
        case undecided
        case visible
        case hiddenStructuredObject
    }

    private var mode: Mode = .undecided
    private var bufferedPrefix = ""

    mutating func consume(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        switch mode {
        case .visible:
            return delta
        case .hiddenStructuredObject:
            return ""
        case .undecided:
            bufferedPrefix += delta
            return decideFromBufferedPrefix()
        }
    }

    private mutating func decideFromBufferedPrefix() -> String {
        let trimmed = bufferedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("{") {
            mode = .hiddenStructuredObject
            bufferedPrefix.removeAll(keepingCapacity: true)
            return ""
        }

        if trimmed.hasPrefix("```") {
            return decideForFence(trimmed)
        }

        return releaseBufferedPrefix()
    }

    private mutating func decideForFence(_ trimmed: String) -> String {
        let lower = trimmed.lowercased()
        let firstLine = lower.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? lower

        if firstLine == "```json" || firstLine == "``` json" {
            mode = .hiddenStructuredObject
            bufferedPrefix.removeAll(keepingCapacity: true)
            return ""
        }

        guard trimmed.contains("\n") else { return "" }
        let body = trimmed.components(separatedBy: .newlines).dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{") {
            mode = .hiddenStructuredObject
            bufferedPrefix.removeAll(keepingCapacity: true)
            return ""
        }

        return releaseBufferedPrefix()
    }

    private mutating func releaseBufferedPrefix() -> String {
        mode = .visible
        let output = bufferedPrefix
        bufferedPrefix.removeAll(keepingCapacity: true)
        return output
    }
}
