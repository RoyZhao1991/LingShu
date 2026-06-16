import Foundation

/// 唤醒词匹配（纯函数，可单测）：ASR 把"灵枢"转写得并不稳定（同音/近音字常见），
/// 死板的 `contains("灵枢")` 会让"用灵枢关键词也唤不醒"（实测 bug #4）。
/// 这里做**归一化 + 同音近音变体**的宽松匹配：抹空白/标点/大小写后，命中配置词或其常见误转写即算唤醒。
enum LingShuWakeWordMatcher {

    /// "灵枢"在中文 ASR 下的常见误转写（同音/近音）。命中任一即视为点名灵枢。
    /// 取舍：宁可宽一点（多接住几句），也不要"喊了名字却唤不醒"。
    static let lingShuVariants: [String] = [
        "灵枢", "灵书", "灵舒", "灵姝", "灵殊", "灵树", "灵数", "灵叔", "灵苏",
        "铃枢", "铃书", "凌枢", "凌书", "玲枢", "聆枢", "零枢", "령枢"
    ]

    /// 归一化：去掉空白与标点、转小写——让"灵枢，"≈"灵枢"≈"灵 枢"。
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// 文本是否点名了灵枢（宽松：配置唤醒词 + 内建同音近音变体）。
    static func contains(_ text: String, wakeWord: String) -> Bool {
        let haystack = normalize(text)
        guard !haystack.isEmpty else { return false }
        var needles = lingShuVariants
        let configured = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { needles.append(configured) }
        return needles.contains { haystack.contains(normalize($0)) }
    }

    /// 剥掉句首的唤醒词，返回真正的指令体（"灵枢，介绍一下你自己" → "介绍一下你自己"）。
    /// 任一变体命中即从其后切；都不命中则原样返回（已在对话态、整句都是指令）。
    static func stripWakeWord(from text: String, wakeWord: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var needles = lingShuVariants
        let configured = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { needles.append(configured) }
        // 优先用最长变体切，避免"灵枢"先命中却把更长误转写残留。
        for needle in needles.sorted(by: { $0.count > $1.count }) {
            if let range = trimmed.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                let tail = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                return tail.isEmpty ? trimmed : tail   // 只有唤醒词、没指令 → 保留原文(当成招呼)
            }
        }
        return trimmed
    }
}
