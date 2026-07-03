import Foundation

/// 从用户自然语言里提取"本轮明确指定的工作目录"。
///
/// 这是通用执行边界,不是业务特判:用户把产出限定到某个目录/文件夹/路径时,
/// 工具层必须把相对路径和命令默认落到那里,否则模型即便做对了也会写偏。
enum LingShuWorkingDirectoryHint {
    static func explicitDirectory(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for match in quotedPathMatches(in: trimmed) + unquotedPathMatches(in: trimmed) {
            guard let candidate = normalizeCandidate(match.path) else { continue }
            let directoryIntent = containsDirectoryIntent(match.prefix)
            if let dir = directory(from: candidate, directoryIntent: directoryIntent) {
                return dir
            }
        }
        return nil
    }

    private struct PathMatch {
        var prefix: String
        var path: String
    }

    private static func quotedPathMatches(in text: String) -> [PathMatch] {
        let pattern = #"(?i)(.{0,24}?)(在|到|进入|切到|保存到|写到|放到|输出到|生成到|目录|文件夹|folder|dir|workspace|工作目录)\s*[:：]?\s*[`"']([^`"']+)[`"']"#
        return matches(pattern: pattern, text: text).compactMap { groups in
            guard groups.count >= 4 else { return nil }
            return PathMatch(prefix: groups[1] + groups[2], path: groups[3])
        }
    }

    private static func unquotedPathMatches(in text: String) -> [PathMatch] {
        let pattern = #"(?i)(.{0,24}?)(在|到|进入|切到|保存到|写到|放到|输出到|生成到|目录|文件夹|folder|dir|workspace|工作目录)\s*[:：]?\s*([~/][^\s，,。；;：:"'）)\]】]+)"#
        return matches(pattern: pattern, text: text).compactMap { groups in
            guard groups.count >= 4 else { return nil }
            return PathMatch(prefix: groups[1] + groups[2], path: groups[3])
        }
    }

    private static func matches(pattern: String, text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).map { result in
            (0..<result.numberOfRanges).map { idx in
                let r = result.range(at: idx)
                guard r.location != NSNotFound else { return "" }
                return ns.substring(with: r)
            }
        }
    }

    private static func normalizeCandidate(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'，,。；;：:）)]】"))
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("~") {
            path = NSString(string: path).expandingTildeInPath
        }
        guard path.hasPrefix("/") else { return nil }
        return (path as NSString).standardizingPath
    }

    private static func containsDirectoryIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["目录", "文件夹", "工作目录", "folder", "dir", "workspace"].contains { lower.contains($0) }
    }

    private static func directory(from path: String, directoryIntent: Bool) -> String? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? nil : (dir as NSString).standardizingPath
        }
        if directoryIntent {
            return path
        }
        return nil
    }
}
