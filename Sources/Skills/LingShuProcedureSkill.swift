import Foundation

/// **过程型技能(Record & Replay 的产物)**:用户**做一遍演示**,灵枢理解逻辑后存成这个——
/// 一串「按意图描述的操作步骤」(不是坐标录像)+ 抽出来的「会变的参数」。以后一句话带新参数即可 replay。
///
/// 设计取向(对标 Codex Record & Replay,2026-06-25):
/// - **理解意图、不记坐标**:步骤是「科目选差旅费」「金额填 {{金额}}」,UI 改版换位置也能按意图找元素(replay 走 computer-use/AX/视觉)。
/// - **参数 vs 配置**:抽出会变的(金额/日期/审批人)做参数,固定的(差旅费/提交)写死进步骤。
/// - **存成 SKILL.md**:复用灵枢现成技能目录 `~/Library/Application Support/LingShu/Skills/*.md`,跨工具可读(Claude 等也认)。
struct LingShuProcedureSkill: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var triggers: [String]          // 「用报销技能」「报销」等触发说法
    var appHint: String?            // 主要在哪个 app 里操作(replay 时先切到它)
    var parameters: [Param]         // 会变的输入(步骤里以 {{name}} 占位)
    var steps: [String]             // 有序操作步骤(按意图描述,可含 {{name}} 占位)

    struct Param: Codable, Equatable, Sendable {
        var name: String            // 如「金额」
        var description: String     // 如「报销金额」
        var example: String         // 如「3600」
    }

    init(id: String, title: String, triggers: [String], appHint: String? = nil, parameters: [Param] = [], steps: [String] = []) {
        self.id = id
        self.title = title
        self.triggers = triggers
        self.appHint = appHint
        self.parameters = parameters
        self.steps = steps
    }

    /// 把参数值填进步骤(`{{金额}}` → 4800)。未提供的占位保持原样(replay 时会暴露缺参)。
    func resolvedSteps(_ values: [String: String]) -> [String] {
        steps.map { step in
            var s = step
            for (k, v) in values { s = s.replacingOccurrences(of: "{{\(k)}}", with: v) }
            return s
        }
    }

    /// 步骤里**还没填上**的参数(占位仍在)——replay 前据此判断哪些参数必须问用户。
    func missingParameters(given values: [String: String]) -> [String] {
        parameters.map(\.name).filter { name in
            values[name] == nil && steps.contains { $0.contains("{{\(name)}}") }
        }
    }
}

// MARK: - SKILL.md 读写(复用灵枢技能 .md 约定:frontmatter + 小节)

extension LingShuProcedureSkill {
    /// 序列化成技能 .md(`kind: procedure` 标记为过程型,与现有"专家档案"技能区分)。
    func toMarkdown() -> String {
        var lines: [String] = ["---"]
        lines.append("id: \(id)")
        lines.append("title: \(title)")
        lines.append("kind: procedure")
        lines.append("triggers: \(triggers.joined(separator: ", "))")
        if let appHint, !appHint.isEmpty { lines.append("app: \(appHint)") }
        lines.append("---")
        lines.append("")
        lines.append("## 操作步骤")
        for (i, step) in steps.enumerated() { lines.append("\(i + 1). \(step)") }
        if !parameters.isEmpty {
            lines.append("")
            lines.append("## 参数")
            for p in parameters { lines.append("- \(p.name): \(p.description)\(p.example.isEmpty ? "" : "(例 \(p.example))")") }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// 从技能 .md 解析过程型技能;`kind` 不是 procedure → 返回 nil(那是普通专家技能,不归这里管)。
    static func parse(markdown: String, fallbackID: String) -> LingShuProcedureSkill? {
        var frontmatter: [String: String] = [:]
        var body = markdown
        if markdown.hasPrefix("---") {
            let parts = markdown.components(separatedBy: "---")
            if parts.count >= 3 {
                for line in parts[1].components(separatedBy: .newlines) {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { frontmatter[key] = value }
                }
                body = parts[2...].joined(separator: "---")
            }
        }
        guard (frontmatter["kind"]?.lowercased()) == "procedure" else { return nil }
        let title = frontmatter["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        let sections = Self.splitSections(body)
        let steps = Self.numberedOrBulletLines(sections["操作步骤"] ?? sections["steps"] ?? "")
        guard !steps.isEmpty else { return nil }   // 没步骤的过程技能没意义
        let params = Self.parseParams(sections["参数"] ?? sections["parameters"] ?? "")
        let triggers = (frontmatter["triggers"] ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        return LingShuProcedureSkill(
            id: frontmatter["id"]?.nonEmptyOrNil ?? fallbackID,
            title: title,
            triggers: triggers.isEmpty ? [title] : triggers,
            appHint: frontmatter["app"]?.nonEmptyOrNil,
            parameters: params,
            steps: steps
        )
    }

    // MARK: 解析辅助

    private static func splitSections(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var buffer: [String] = []
        func flush() { if let c = current { result[c] = buffer.joined(separator: "\n") }; buffer = [] }
        for line in body.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                flush()
                current = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else { buffer.append(line) }
        }
        flush()
        return result
    }

    /// 解析有序(`1. `)或无序(`- `)步骤行。
    private static func numberedOrBulletLines(_ section: String) -> [String] {
        section.components(separatedBy: .newlines).compactMap { raw -> String? in
            var t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if let dot = t.firstIndex(of: "."), let n = Int(t[..<dot]), n >= 0 {   // "3. xxx"
                t = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else { return nil }
            return t.isEmpty ? nil : t
        }
    }

    /// 解析「- 金额: 报销金额(例 3600)」式参数行。
    private static func parseParams(_ section: String) -> [Param] {
        section.components(separatedBy: .newlines).compactMap { raw -> Param? in
            var t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
            t = String(t.dropFirst(2))
            guard let colon = t.firstIndex(of: ":") ?? t.firstIndex(of: "：") else { return nil }
            let name = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
            var desc = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var example = ""
            if let r = desc.range(of: "(例 "), let end = desc.range(of: ")", range: r.upperBound..<desc.endIndex) {
                example = String(desc[r.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                desc = String(desc[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return name.isEmpty ? nil : Param(name: name, description: desc, example: example)
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
