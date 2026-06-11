import Foundation

/// 处理模型内联推理标签。MiniMax M3 等模型会把思考过程放进 `<think>…</think>`
/// 内联在 content 里；正文展示时必须剥离，避免把思考当成回复给用户。
enum LingShuReasoningText {
    /// 去掉成对的 `<think>…</think>`（含跨行）；同时处理只剩开/闭标签的残段。
    static func stripThinkTags(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(
            pattern: "<think>[\\s\\S]*?</think>",
            options: [.caseInsensitive]
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // 流式未闭合的残留标签兜底清理。
        result = result.replacingOccurrences(of: "<think>", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
