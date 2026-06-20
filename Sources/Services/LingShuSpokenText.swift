import Foundation

/// 朗读文本净化(用户要求:带格式的内容**念概要、不念格式**)。把回复里的 markdown/枚举/代码/表格等"格式内容"
/// 处理成适合 TTS 的干净话:有前导散文就只念前导 + "详情见屏幕",纯结构则取首条要点;始终剥掉 **/`/#/列表符号/状态 emoji。
/// 纯逻辑可单测。
enum LingShuSpokenText {

    /// 把一条回复压成适合朗读的话:格式内容只给概要。
    static func concise(_ text: String) -> String {
        let noCode = stripCodeFences(text)
        var lead: [String] = []
        var hasStructure = false
        for raw in noCode.components(separatedBy: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if isStructuralLine(s) { hasStructure = true; break }   // 到第一条结构行(列表/表格/标题)就停
            lead.append(stripInlineMarkdown(s))
        }
        var spoken = lead.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if spoken.isEmpty {
            // 没有前导散文(开头就是结构)→ 取首条结构项文本当概要。
            if let first = noCode.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { isStructuralLine($0) }) {
                spoken = stripInlineMarkdown(stripStructureMarker(first))
            }
        }
        if hasStructure {
            spoken = spoken.isEmpty ? "我整理了几条,详情看屏幕。" : spoken + "(详情看屏幕)"
        }
        return spoken.isEmpty ? stripInlineMarkdown(text) : spoken
    }

    /// 是否结构行(枚举/项目符号/标题/表格)——这类不逐字念。
    static func isStructuralLine(_ s: String) -> Bool {
        if LingShuChoiceParsing.strippedMarker(s) != nil { return true }   // 1./①/1️⃣ 枚举
        for p in ["- ", "* ", "• ", "+ ", "## ", "### ", "#### ", "> "] where s.hasPrefix(p) { return true }
        if s.hasPrefix("#") { return true }
        if s.hasPrefix("|") && s.contains("|") { return true }   // 表格行
        return false
    }

    static func stripStructureMarker(_ s: String) -> String {
        if let m = LingShuChoiceParsing.strippedMarker(s) { return m }
        var t = s
        for p in ["- ", "* ", "• ", "+ ", "#### ", "### ", "## ", "> "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 剥行内 markdown + 链接 + 状态 emoji(留正文)。
    static func stripInlineMarkdown(_ s: String) -> String {
        var t = s
        // 链接 [文字](url) → 文字
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        // 去强调/代码标记 ** * _ ` ~
        for ch in ["**", "`", "~~"] { t = t.replacingOccurrences(of: ch, with: "") }
        t = t.replacingOccurrences(of: "(?<=\\S)\\*(?=\\S)", with: "", options: .regularExpression)
        // 行首 markdown 标题 #
        t = t.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        // 常见状态 emoji(念出来很怪)
        for e in ["✅", "⚠️", "⏸", "🌐", "🔄", "❌", "⛔", "✔️", "①", "②", "③"] { t = t.replacingOccurrences(of: e, with: "") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func stripCodeFences(_ text: String) -> String {
        // 去掉 ```…``` 围栏代码块(整段不念)。
        let stripped = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        return stripped
    }
}
