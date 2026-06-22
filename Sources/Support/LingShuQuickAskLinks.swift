import Foundation

/// 快速面板·**回复里的可操作项提取**(纯逻辑,可单测):从灵枢回复文本里抽出**可点开**的文件路径与网址
/// (recall_local 命中的本机文件、浏览历史 history://<url>、正文里的链接),供面板渲染成可点击/可执行的行。
struct LingShuQuickLink: Equatable, Sendable {
    enum Kind: Sendable { case file, url }
    let kind: Kind
    let display: String   // 展示名(文件名 / 网址)
    let target: String    // 实际打开目标(绝对路径 / 网址)
}

enum LingShuQuickAskLinks {
    static func extract(from text: String,
                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [LingShuQuickLink] {
        var out: [LingShuQuickLink] = []
        var seen = Set<String>()
        func add(_ link: LingShuQuickLink) {
            guard !seen.contains(link.target) else { return }
            seen.insert(link.target); out.append(link)
        }

        // 1. history://<url> → 取内层真实网址(浏览历史命中)。
        for m in matches(text, "history://[^\\s]+") {
            let url = trimPunct(String(m.dropFirst("history://".count)))
            if url.hasPrefix("http") { add(.init(kind: .url, display: url, target: url)) }
        }
        // 2. http(s) 链接。
        for m in matches(text, "https?://[^\\s)）」\"']+") {
            let url = trimPunct(m)
            if !url.isEmpty { add(.init(kind: .url, display: url, target: url)) }
        }
        // 3. 存在的绝对文件路径(recall_local 命中文件)。
        for m in matches(text, "/[^\\s:)\"'）」]+") {
            let p = trimPunct(m)
            guard p.count > 1, p.contains("/"), fileExists(p) else { continue }
            add(.init(kind: .file, display: (p as NSString).lastPathComponent, target: p))
        }
        return out
    }

    private static func matches(_ text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func trimPunct(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " 。,，、;:)）」\"'\n\t"))
    }
}
