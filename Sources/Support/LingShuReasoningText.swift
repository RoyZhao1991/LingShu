import Foundation

/// 处理模型内联推理标签。不同模型用不同写法把思考过程内联进 content：
/// `<think>…</think>`（MiniMax/Qwen/DeepSeek 蒸馏）、`<mm:think>…</mm:think>`（MiniMax M 系命名空间变体）、
/// `<thinking>…</thinking>` 等。正文展示时必须**全部**剥离，避免把英文思考链当成回复甩给用户。
enum LingShuReasoningText {
    // 任意命名空间/变体的 think 标签：<think> / <mm:think> / <thinking> / </…think…> 都覆盖。
    private static let pairedBlock = "<[a-z0-9_.:-]*think[a-z0-9_.:-]*>[\\s\\S]*?</[a-z0-9_.:-]*think[a-z0-9_.:-]*>"
    // 仅当闭标签**后面还有真正内容**时，才把闭标签之前当成思考前缀整段剥掉（`(?=\s*\S)` 前瞻）。
    // 否则像 `答案</think>` 这种"内容在前、末尾挂个残标签"会被误删——那种交给 bareTag 只摘标签。
    private static let orphanCloseAndBefore = "^[\\s\\S]*?</[a-z0-9_.:-]*think[a-z0-9_.:-]*>(?=\\s*\\S)"
    private static let bareTag = "</?[a-z0-9_.:-]*think[a-z0-9_.:-]*>"

    /// 去掉成对的 think 块（含跨行、任意变体）；再处理"开标签缺失、只剩闭标签"的残段
    /// （把闭标签**之前**的思考前缀整段剥掉）；最后清理残留裸标签。
    static func stripThinkTags(_ text: String) -> String {
        var result = replacingMatches(in: text, pattern: pairedBlock)
        result = replacingMatches(in: result, pattern: orphanCloseAndBefore)
        result = replacingMatches(in: result, pattern: bareTag)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingMatches(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
