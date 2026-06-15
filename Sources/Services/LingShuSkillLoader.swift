import Foundation

/// 用户自定义专家技能：放在 ~/Library/Application Support/LingShu/Skills/*.md，
/// 带 frontmatter（id/title/mission/triggers）+ 正文小节（专业要点/交付物模板/评审清单）。
/// 内置专家是出厂能力，用户技能是可插拔扩展——对应 ROADMAP 的"能力节点插件化"。
enum LingShuSkillLoader {
    static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LingShu/Skills", isDirectory: true)

    /// 加载目录下全部技能文件，解析成专家档案（带触发词）。
    static func loadSkills(from directory: URL = defaultDirectory) -> [LoadedSkill] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> LoadedSkill? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parse(text, fallbackID: url.deletingPathExtension().lastPathComponent)
            }
    }

    struct LoadedSkill: Equatable, Sendable {
        let profile: LingShuExpertProfile
        let triggers: [String]
    }

    /// 解析单个技能 Markdown。frontmatter 必填 title；缺小节用空集合兜底。
    static func parse(_ text: String, fallbackID: String) -> LoadedSkill? {
        var frontmatter: [String: String] = [:]
        var body = text

        if text.hasPrefix("---") {
            let parts = text.components(separatedBy: "---")
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

        let title = frontmatter["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        let sections = splitSections(body)
        let knowledge = bulletLines(sections["专业要点"] ?? sections["knowledge"] ?? "")
        let checklist = bulletLines(sections["评审清单"] ?? sections["checklist"] ?? "")
        let template = (sections["交付物模板"] ?? sections["template"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let triggers = (frontmatter["triggers"] ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 可选的自带生成器脚本（## 生成脚本 里的代码块）：过安全门控才挂上，挡住危险代码。
        let rawScript = extractCodeBlock(sections["生成脚本"] ?? sections["script"] ?? "")
        var bundledScript: String?
        var bundledScriptName: String?
        if !rawScript.isEmpty, LingShuSkillSafetyGate.scan(rawScript).isSafe {
            bundledScript = rawScript
            bundledScriptName = frontmatter["script_name"]?.nonEmpty ?? "generator.py"
        }

        let profile = LingShuExpertProfile(
            id: "skill-" + (frontmatter["id"]?.nonEmpty ?? fallbackID),
            title: title,
            mission: frontmatter["mission"]?.nonEmpty ?? "用户自定义专家技能。",
            knowledgeHighlights: knowledge,
            deliverableTemplate: template.isEmpty ? "# \(title) 交付\n## 内容" : template,
            reviewChecklist: checklist.isEmpty ? ["交付物是否覆盖任务要求"] : checklist,
            bundledScript: bundledScript,
            bundledScriptName: bundledScriptName
        )
        return .init(profile: profile, triggers: triggers)
    }

    /// 暴露候选 skill markdown 里**原始**(未过安全门)的自带脚本——供自发现(`LingShuSkillAcquisition`)
    /// 在装之前先跑静态门 + LLM 风险审。无脚本小节返回 nil。注:`parse` 只在过门后才挂 bundledScript,
    /// 所以判断"带不带脚本"必须看原始内容,不能看解析结果。
    static func rawBundledScript(in markdown: String) -> String? {
        var body = markdown
        if markdown.hasPrefix("---") {
            let parts = markdown.components(separatedBy: "---")
            if parts.count >= 3 { body = parts[2...].joined(separator: "---") }
        }
        let sections = splitSections(body)
        let raw = extractCodeBlock(sections["生成脚本"] ?? sections["script"] ?? "")
        return raw.isEmpty ? nil : raw
    }

    private static func splitSections(_ body: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentTitle: String?
        var buffer: [String] = []
        func flush() {
            if let title = currentTitle {
                sections[title] = buffer.joined(separator: "\n")
            }
            buffer = []
        }
        for line in body.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return sections
    }

    /// 从小节里抽出第一个围栏代码块的内容；没有围栏则把整段当脚本。
    private static func extractCodeBlock(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("```") else { return trimmed }
        let parts = trimmed.components(separatedBy: "```")
        guard parts.count >= 2 else { return trimmed }
        // parts[1] 是第一个 ``` 之后的内容；首行可能是语言标签（python），去掉。
        var block = parts[1]
        if let firstNewline = block.firstIndex(of: "\n") {
            let firstLine = block[..<firstNewline].trimmingCharacters(in: .whitespaces)
            if !firstLine.isEmpty, !firstLine.contains(" "), firstLine.count < 16 {
                block = String(block[block.index(after: firstNewline)...])
            }
        }
        return block.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bulletLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("-") || $0.hasPrefix("•") || $0.hasPrefix("*") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 组合专家注册表：内置专家 + 用户技能。用户技能触发词命中时优先，否则回退内置匹配。
/// 评审官固定走内置（保证评审基线不被用户覆盖）。
///
/// **class（非 struct):支持运行时热重载用户 skill**——dreaming 离线固化把新 skill 落盘到用户 Skills 目录后,
/// 调 `reloadUserSkills()` 即可**免重启生效**(原 struct 单次加载需重启)。userSkills 受锁保护,@unchecked Sendable。
final class LingShuCompositeExpertRegistry: LingShuExpertProfileProviding, @unchecked Sendable {
    private let builtIn = LingShuExpertProfileRegistry()
    private let lock = NSLock()
    private var userSkills: [LingShuSkillLoader.LoadedSkill]

    init(userSkills: [LingShuSkillLoader.LoadedSkill] = LingShuSkillLoader.loadSkills()) {
        self.userSkills = userSkills
    }

    /// 热重载:从磁盘重新读用户 Skills 目录(dreaming 固化 / 用户新增 .md 后调用,免重启即时生效)。
    /// `directory` 仅测试注入用;生产用默认目录。
    func reloadUserSkills(from directory: URL = LingShuSkillLoader.defaultDirectory) {
        let reloaded = LingShuSkillLoader.loadSkills(from: directory)
        lock.lock(); userSkills = reloaded; lock.unlock()
    }

    private var snapshotUserSkills: [LingShuSkillLoader.LoadedSkill] {
        lock.lock(); defer { lock.unlock() }
        return userSkills
    }

    func profile(for taskText: String) -> LingShuExpertProfile {
        let normalized = taskText.lowercased()
        // ① 用户自有 skill 最优先——用户装的就是权威。
        if let matched = snapshotUserSkills.first(where: { skill in
            skill.triggers.contains { normalized.contains($0.lowercased()) }
        }) {
            return matched.profile
        }
        // ② 策展 skill 库自动引入（纯提示、质量分排序、零执行风险）——自进化 Phase 1。
        if let curated = LingShuCuratedSkillRegistry.bestSkill(forTask: taskText) {
            return curated.profile
        }
        // ③ 内置出厂专家兜底。
        return builtIn.profile(for: taskText)
    }

    func reviewerProfile() -> LingShuExpertProfile {
        builtIn.reviewerProfile()
    }

    var allProfiles: [LingShuExpertProfile] {
        builtIn.allProfiles + snapshotUserSkills.map(\.profile)
    }

    var userSkillCount: Int { snapshotUserSkills.count }
}
