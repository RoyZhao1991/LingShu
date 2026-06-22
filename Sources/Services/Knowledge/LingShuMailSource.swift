import Foundation

/// 本机知识·**邮件源**(多源接入):遍历 ~/Library/Mail 下的 .emlx 邮件,抽 主题/发件人/正文摘要 → "那封关于X的邮件说了啥"能找回。
/// 全本地读取、零上传;需系统「完全磁盘访问」才读得到 ~/Library/Mail。走统一增量管线(scan→ingest)。
enum LingShuMailSource {
    static var mailRoot: String { (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mail") }
    static let pathPrefix = "mail://"
    static func owns(_ path: String) -> Bool { path.hasPrefix(pathPrefix) }

    /// 扫描 ~/Library/Mail 的 .emlx → 归一成 `LingShuKnowledgeScan`(**增量:mtime 未变的不重新解析**——大邮箱关键优化)。
    static func scan(root: String? = nil, limit: Int = 3000, knownMtime: (String) -> Double?) -> LingShuKnowledgeScan {
        let base = root ?? mailRoot
        var scan = LingShuKnowledgeScan()
        guard FileManager.default.fileExists(atPath: base) else { return scan }
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return scan }

        var files: [(url: URL, mtime: Double)] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "emlx" {
            let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast).timeIntervalSince1970
            files.append((url, mtime))
            if files.count > limit * 4 { break }
        }
        files.sort { $0.mtime > $1.mtime }
        for item in files.prefix(limit) {
            let path = pathPrefix + item.url.path
            scan.seenPaths.insert(path)
            if knownMtime(path) == item.mtime { continue }   // 增量:这封没变,不重解析
            guard let raw = (try? String(contentsOf: item.url, encoding: .utf8)) ?? (try? String(contentsOf: item.url, encoding: .isoLatin1)),
                  let p = parseEMLX(raw) else { continue }
            scan.changed.append(.init(path: path, mtime: item.mtime,
                                      text: "主题:\(p.subject)\n发件人:\(p.from)\n\(p.body)"))
        }
        return scan
    }

    /// 解析 emlx(纯逻辑,可单测):首行=字节数→丢;随后 RFC822 头(到首个空行)取 Subject/From;之后是正文(到 plist 尾)。
    /// 正文粗清:剥 HTML 标签、压空白、截断。解析不出主题即返回 nil。
    static func parseEMLX(_ raw: String) -> (subject: String, from: String, body: String)? {
        var lines = raw.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        // 首行通常是纯数字字节数,丢掉。
        if Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil { lines.removeFirst() }

        var subject = "", from = ""
        var i = 0
        var lastHeaderWasSubject = false, lastHeaderWasFrom = false
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; break }   // 头结束
            let lower = line.lowercased()
            if lower.hasPrefix("subject:") { subject = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces); lastHeaderWasSubject = true; lastHeaderWasFrom = false }
            else if lower.hasPrefix("from:") { from = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces); lastHeaderWasFrom = true; lastHeaderWasSubject = false }
            else if line.hasPrefix(" ") || line.hasPrefix("\t") {   // 折行续接
                if lastHeaderWasSubject { subject += " " + line.trimmingCharacters(in: .whitespaces) }
                else if lastHeaderWasFrom { from += " " + line.trimmingCharacters(in: .whitespaces) }
            } else { lastHeaderWasSubject = false; lastHeaderWasFrom = false }
            i += 1
        }
        // 正文:头之后到 plist 尾(<?xml / <plist)。
        var bodyLines: [String] = []
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("<?xml") || line.contains("<plist") { break }
            bodyLines.append(line); i += 1
        }
        let body = cleanBody(bodyLines.joined(separator: "\n"))
        guard !subject.isEmpty || !body.isEmpty else { return nil }
        return (subject.isEmpty ? "(无主题)" : subject, from, body)
    }

    /// 正文粗清:剥 HTML 标签、解 &nbsp; 类实体、压空白、截断到 ~1200 字。
    static func cleanBody(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\s*\\n\\s*){2,}", with: "\n", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
    }
}
