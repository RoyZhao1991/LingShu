import Foundation

/// skill 自发现 + 自安装的**编排层**(自进化 Phase 2)——把 `LingShuSkillAcquisition` 的纯逻辑 + 安全模型
/// 接进 agent 循环:本地无匹配 skill 时,联网找候选 → 解析分类 → 静态门 + LLM 风险审 → 安全安装 + 热加载。
///
/// 复用(不重造):web_search(`webSearchLinks`)、无工具小会话(`makeAgentModelAdapter` + `LingShuAgentSession`)、
/// 热加载(`reloadUserSkills`)、安全门(`LingShuSkillSafetyGate`)、首次运行审批(`requestShellApproval` + 隔离表)。
/// 安全红线:纯提示直接装;带脚本过静态门后调大模型风险审,无风险才自动装,有风险装但首次运行必经审批,
/// **绝不静默自动执行未审来源代码**([[skill-self-evolution]])。
@MainActor
extension LingShuState {

    /// discover_skill 工具:本地没有合适技能时,联网找评价好的 skill 并按安全模型自动安装(纯提示直接装,
    /// 带脚本走静态门 + 风险审 + 高风险首次运行审批)。装好即热加载,之后用 apply_skill 取用。
    func discoverSkillTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "discover_skill",
            description: "本地没有匹配的专家技能时,联网找现成的高质量 skill 并自动安装(纯提示技能直接装、带脚本技能过安全审核后装,高风险脚本首次运行需你审批),装好后用 apply_skill 取用。遇到不擅长的新领域、想要现成专家方案时调用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"要找技能的任务/领域(如 'PDF 表格抽取' / 'SQL 优化')\"}},\"required\":[\"task\"]}"
        ) { [weak self] argsJSON in
            let task = Self.jsonField(argsJSON, "task") ?? argsJSON
            guard let self else { return "技能自发现不可用。" }
            return await self.discoverSkill(task: task)
        }
    }

    /// 查本地 → 联网找候选 → 分类(静态门)→ 风险审 → 安全安装 + 热加载。返回给模型的说明。
    func discoverSkill(task: String) async -> String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "请说清要找什么领域的技能。" }

        // ① 本地已有匹配 skill(用户/策展)→ 不必联网,直接用。
        let local = expertProfileRegistry.profile(for: trimmed)
        if local.id.hasPrefix("skill-") {
            return "本地已有匹配技能「\(local.title)」,直接用 apply_skill 取用即可,无需联网找。"
        }

        // ② 联网找候选(DuckDuckGo 常被限流 → 可能空,不致命)。
        let raw = await Self.webSearchLinks("\(trimmed) claude agent skill SKILL.md github", limit: 8)
        let candidates = LingShuSkillAcquisition.rankCandidates(raw).map { Self.rawGitHubURL($0) }
        guard !candidates.isEmpty else {
            return "联网没找到「\(trimmed)」的现成 skill 候选(搜索可能被限流)。本次先用通用能力(write_file/run_command 组合)推进,别空等。"
        }

        var blocked: [String] = []
        for url in candidates.prefix(6) {
            guard let markdown = await Self.fetchSkillMarkdown(url) else { continue }
            let slug = Self.skillSlug(from: url, fallback: trimmed)
            let forcedID = "discovered-\(slug)"
            let namespaced = Self.forceFrontmatterID(markdown, to: forcedID)   // 命名空间隔离,绝不覆盖内置/策展 skill
            guard let (skill, kind) = LingShuSkillAcquisition.classify(markdown: namespaced, fallbackID: forcedID) else { continue }

            switch kind {
            case .promptOnly:
                guard installDiscoveredSkill(markdown: namespaced, fileSlug: forcedID) else { continue }
                return "已联网找到并安装**纯提示技能**「\(skill.profile.title)」(零执行风险,已热加载)。来源:\(url.host ?? "web")。现在用 apply_skill 按它推进。"

            case .scriptBlockedByGate(let violations):
                blocked.append("「\(skill.profile.title)」含危险代码被静态门拦下(\(violations.joined(separator: "、")))")
                continue   // 不装,换下一个候选

            case .scriptNeedsRiskReview(let script):
                let verdict = await reviewScriptRisk(script)
                guard installDiscoveredSkill(markdown: namespaced, fileSlug: forcedID) else { continue }
                switch verdict {
                case .safe:
                    return "已联网找到并安装**带脚本技能**「\(skill.profile.title)」(过静态安全门 + 风险审判定无明显风险,已热加载)。脚本执行仍会走常规授权。来源:\(url.host ?? "web")。"
                case .risky(let points):
                    LingShuSkillAcquisition.setQuarantine(skillID: skill.profile.id, riskNotes: points)
                    return "已联网找到并安装**带脚本技能**「\(skill.profile.title)」,但风险审标记了风险点,已隔离:**首次运行它的脚本时会弹审批让你裁决**(即便已选过完全授权)。风险点:\(points.joined(separator: "; "))。来源:\(url.host ?? "web")。可先用 apply_skill 取它的提示部分。"
                }
            }
        }

        let blockedNote = blocked.isEmpty ? "" : "(已拦下不安全候选:\(blocked.joined(separator: ";")))"
        return "联网找到了页面但没拿到可安全安装的「\(trimmed)」skill\(blockedNote)。本次先用通用能力推进,别空等。"
    }

    /// 调大模型对来源不明的脚本做风险审(无工具小会话)。拿不到结果 → 保守按有风险(fail-safe)。
    func reviewScriptRisk(_ script: String) async -> LingShuSkillAcquisition.RiskVerdict {
        let prompt = """
        审计下面这段【来源不明】的 skill 自带脚本的安全风险。只看代码本身,判断它执行时是否可能:
        删除/覆盖用户文件、外传数据、联网下载并执行、读敏感凭据(SSH/钥匙串/AWS)、提权、跑危险系统调用。
        **严格输出格式**:第一行只写 `RISK=none` 或 `RISK=low` 或 `RISK=high`;之后每行列一条具体风险点(无风险则不写)。
        脚本:
        ```
        \(script.prefix(6000))
        ```
        """
        let session = LingShuAgentSession(
            id: "skill-risk-\(UUID().uuidString.prefix(6))",
            system: "你是严谨的代码安全审计员,只输出风险评级与风险点,不解释、不寒暄;拿不准时保守判高。",
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await session.send(prompt)
        if case .completed(let text) = result {
            return LingShuSkillAcquisition.parseRiskVerdict(LingShuReasoningText.stripThinkTags(text))
        }
        return .risky(["风险审未能完成(模型无响应),保守要求首次运行审批"])
    }

    /// 把候选 skill 落盘到用户 Skills 目录 + 热加载 + 登记进资源 manifest(下次复用)。
    func installDiscoveredSkill(markdown: String, fileSlug: String) -> Bool {
        let dir = LingShuSkillLoader.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(fileSlug).md")
        guard (try? markdown.write(to: fileURL, atomically: true, encoding: .utf8)) != nil else { return false }
        (expertProfileRegistry as? LingShuCompositeExpertRegistry)?.reloadUserSkills()
        LingShuResourceRegistry.shared.register(
            kind: "skill", name: fileSlug, tags: [fileSlug],
            localPath: fileURL.path, source: "discover_skill", license: "discovered(自发现,已过安全模型)")
        return true
    }

    // MARK: - 纯工具(nonisolated static,可单测/复用)

    /// GitHub blob 页面链接 → raw 直链(blob/<branch>/ → raw.githubusercontent.com/.../<branch>/),其它原样返回。
    nonisolated static func rawGitHubURL(_ url: URL) -> URL {
        let s = url.absoluteString
        guard s.contains("github.com"), s.contains("/blob/") else { return url }
        let raw = s.replacingOccurrences(of: "github.com", with: "raw.githubusercontent.com")
                   .replacingOccurrences(of: "/blob/", with: "/")
        return URL(string: raw) ?? url
    }

    /// 从候选 URL 取文件名 slug(去扩展名、净化为 [a-z0-9-]);取不到用任务关键词兜底。
    nonisolated static func skillSlug(from url: URL, fallback: String) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let source = base.isEmpty || base.lowercased() == "skill" ? fallback : base
        let cleaned = source.lowercased().unicodeScalars.map { sc -> Character in
            (CharacterSet.alphanumerics.contains(sc) ? Character(sc) : "-")
        }
        let slug = String(cleaned).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "skill-\(UUID().uuidString.prefix(6))" : String(slug.prefix(40))
    }

    /// 下载候选 markdown 并粗校验"像不像一个 skill"(有 frontmatter title/小节、不是整页 HTML、体积合理)。
    nonisolated static func fetchSkillMarkdown(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) LingShu/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 80, data.count < 400_000,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lower = text.lowercased()
        let looksHTML = lower.contains("<!doctype html") || lower.contains("<html")
        let looksSkill = text.contains("title:") || text.contains("## ")
        guard !looksHTML, looksSkill else { return nil }
        return text
    }

    /// 强制把 frontmatter 的 id 改成 `forcedID`(命名空间隔离:防恶意 skill 用 `id: curated-ppt` 覆盖内置/策展技能)。
    nonisolated static func forceFrontmatterID(_ markdown: String, to forcedID: String) -> String {
        guard markdown.hasPrefix("---") else {
            return "---\nid: \(forcedID)\n---\n\n" + markdown
        }
        let parts = markdown.components(separatedBy: "---")
        guard parts.count >= 3 else { return "---\nid: \(forcedID)\n---\n\n" + markdown }
        var fmLines = parts[1].components(separatedBy: .newlines)
        var replaced = false
        fmLines = fmLines.map { line in
            if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("id:") {
                replaced = true; return "id: \(forcedID)"
            }
            return line
        }
        if !replaced { fmLines.insert("id: \(forcedID)", at: fmLines.isEmpty ? 0 : 1) }
        return "---" + fmLines.joined(separator: "\n") + "---" + parts[2...].joined(separator: "---")
    }
}
