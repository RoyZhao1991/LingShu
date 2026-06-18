import Foundation

/// 记忆 v2 的知识单元 = 一条**原子笔记**(吸收 Obsidian:一个概念一个可寻址单元 + 类型 + 别名 + 双链)。
/// 真相源是 Markdown 文件(人可读/可手改/可 grep/可 diff);本结构是其内存表示。纯值类型,Sendable,可单测。
struct LingShuMemoryNote: Equatable, Sendable, Identifiable {
    /// 知识类型(决定存哪个子目录 + 召回/裁决策略)。
    enum Kind: String, Sendable, CaseIterable {
        case person, project, preference, decision, fact, skill, glossary
    }
    /// 来源(矛盾消解时的权威权重:用户明说 > 工具观测 > 推断)。
    enum Source: String, Sendable {
        case userExplicit = "user-explicit"
        case tool
        case inference
        var weight: Int {
            switch self {
            case .userExplicit: return 3
            case .tool: return 2
            case .inference: return 1
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var aliases: [String]
    var body: String
    var links: [String]          // 指向其它 note 的 id(双链:对端的反查即 backlink)
    var tags: [String]
    var confidence: Double       // 0~1
    var source: Source
    var created: Date
    var updated: Date
    var lastVerified: Date       // 最近一次被确认/召回;衰减以此为基准
    var sensitive: Bool          // 敏感:不出本机、不进云上下文(隐私红线)
    var history: [String]        // 被推翻的旧结论(可回溯)

    // MARK: - Markdown 序列化(frontmatter + 正文 + ## history)

    /// 每次新建(ISO8601DateFormatter 非 Sendable,不能做全局 static let);秒级,无小数 → 往返稳定。
    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    func markdown() -> String {
        var fm = "---\n"
        fm += "id: \(id)\n"
        fm += "kind: \(kind.rawValue)\n"
        fm += "title: \(title)\n"
        fm += "aliases: \(aliases.joined(separator: ", "))\n"
        fm += "links: \(links.joined(separator: ", "))\n"
        fm += "tags: \(tags.joined(separator: ", "))\n"
        fm += "confidence: \(String(format: "%.2f", confidence))\n"
        fm += "source: \(source.rawValue)\n"
        fm += "created: \(Self.isoFormatter().string(from: created))\n"
        fm += "updated: \(Self.isoFormatter().string(from: updated))\n"
        fm += "last_verified: \(Self.isoFormatter().string(from: lastVerified))\n"
        fm += "sensitive: \(sensitive)\n"
        fm += "---\n\n"
        var out = fm + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if !history.isEmpty {
            out += "\n## history\n" + history.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    static func parse(_ text: String) -> LingShuMemoryNote? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<closeIdx] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let id = fields["id"], !id.isEmpty,
              let kind = Kind(rawValue: fields["kind"] ?? "") else { return nil }

        // 正文与 ## history 分离
        let rest = Array(lines[(closeIdx + 1)...])
        var bodyLines: [String] = []
        var historyLines: [String] = []
        var inHistory = false
        for line in rest {
            if line.trimmingCharacters(in: .whitespaces).lowercased() == "## history" { inHistory = true; continue }
            if inHistory {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") { historyLines.append(String(t.dropFirst(2))) }
            } else {
                bodyLines.append(line)
            }
        }

        func list(_ key: String) -> [String] {
            (fields[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func date(_ key: String) -> Date {
            fields[key].flatMap { isoFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        }

        return LingShuMemoryNote(
            id: id,
            kind: kind,
            title: fields["title"] ?? id,
            aliases: list("aliases"),
            body: bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            links: list("links"),
            tags: list("tags"),
            confidence: Double(fields["confidence"] ?? "") ?? 0.5,
            source: Source(rawValue: fields["source"] ?? "") ?? .inference,
            created: date("created"),
            updated: date("updated"),
            lastVerified: date("last_verified"),
            sensitive: (fields["sensitive"] ?? "false") == "true",
            history: historyLines
        )
    }
}
