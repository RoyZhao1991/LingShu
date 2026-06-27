import Foundation

/// 自进化 skill 模块 · Phase 2:**离线固化(与 Anthropic「dreaming」对齐)**。
///
/// 取向(对齐 dreaming/sleep 的离线经验固化):空闲(下班/夜间)时回放**已完成任务的真实轨迹**,
/// 把反复成功的做法蒸馏成**可复用的纯提示型 skill**,并用**实测通过率**当质量分——
/// 不改模型权重也能越用越强。醒来(下次启动)时这些自固化 skill 已并入组合注册表生效。
///
/// **安全模型(2026-06-27 用户校正)**:skill 是**可自由进化的外围**——dreaming **自动触发、自动迭代、静默升级**,
/// 含**生成器**:落盘前每段代码逐块过**自动安全门** `LingShuSkillSafetyGate.scan`(`safetyFilterCode`),安全就保留、
/// 危险才剥。**不需人工授权**——因为这是灵枢从**自己验证过的任务**长出来的(非"未审外部来源")。供应链红线(绝不自动执行
/// **未审外部来源**代码)针对的是 `discover_skill` 拉的外部 skill;**内核 ABI** 固化、改动才需人工授权。两者与 dreaming 自进化各管一段。
/// 见 [skill-self-evolution] / Docs/灵枢内核ABI.md §0「核心固化 → 自我编程外围 → 可插拔进化」。
enum LingShuDreamingConsolidator {

    /// 一条已完成任务的精简回放样本(从 journal 记录映射而来,便于纯逻辑单测)。
    struct Sample: Equatable, Sendable {
        let prompt: String
        let summary: String
        /// 是否通过验收门(status == completed)。未达标/异常 = false,用于算通过率。
        let succeeded: Bool
    }

    /// 一个值得固化的领域候选。
    struct Candidate: Equatable, Sendable {
        let domain: String       // 任务类型键(presentation/crawler/...)
        let title: String        // 中文领域名
        let triggers: [String]   // 触发词
        let successes: [Sample]   // 该领域的成功样本
        let total: Int           // 该领域终态样本总数(成功+失败)
        var passRate: Double { total == 0 ? 0 : Double(successes.count) / Double(total) }
    }

    /// 蒸馏出的纯提示 skill(可落盘)。
    struct DistilledSkill: Equatable, Sendable {
        let domain: String
        let markdown: String
        let qualityScore: Double
        let sampleCount: Int
    }

    // MARK: - 领域分类(纯函数,可测)

    /// 已知交付型任务类型 →(中文名, 触发词)。只为这些有意义的领域固化,泛化闲聊不固化。
    static let knownDomains: [(domain: String, title: String, triggers: [String])] = [
        ("presentation", "PPT 演示", ["ppt", "演示", "幻灯", "slides", "presentation", "汇报", "路演"]),
        ("crawler", "网页爬虫", ["爬虫", "抓取", "爬取", "scrape", "crawler", "采集"]),
        ("document", "文档写作", ["文档", "报告", "word", "docx", "说明书", "方案"]),
        ("spreadsheet", "表格处理", ["表格", "excel", "xlsx", "csv", "统计表"]),
        ("script", "脚本程序", ["脚本", "程序", "代码", "自动化", "小工具"]),
    ]

    static func domain(for prompt: String) -> (domain: String, title: String, triggers: [String])? {
        let p = prompt.lowercased()
        return knownDomains.first { entry in entry.triggers.contains { p.contains($0.lowercased()) } }
    }

    // MARK: - 候选挖掘(纯函数,可测)

    /// 从回放样本里挖出值得固化的领域:同领域成功样本 ≥ `minSamples` 且通过率 ≥ `minPassRate`,
    /// 且该领域**尚未被现有 skill 覆盖**(`existingDomains`,避免覆盖打磨过的策展/用户 skill)。
    /// 结果按通过率降序。
    static func candidates(
        from samples: [Sample],
        existingDomains: Set<String>,
        minSamples: Int = 3,
        minPassRate: Double = 0.6
    ) -> [Candidate] {
        var byDomain: [String: (title: String, triggers: [String], all: [Sample])] = [:]
        for sample in samples {
            guard let d = domain(for: sample.prompt) else { continue }
            byDomain[d.domain, default: (d.title, d.triggers, [])].all.append(sample)
        }
        var result: [Candidate] = []
        for (domainKey, group) in byDomain {
            guard !existingDomains.contains(domainKey) else { continue }
            let successes = group.all.filter(\.succeeded)
            guard successes.count >= minSamples else { continue }
            let candidate = Candidate(
                domain: domainKey,
                title: group.title,
                triggers: group.triggers,
                successes: successes,
                total: group.all.count
            )
            guard candidate.passRate >= minPassRate else { continue }
            result.append(candidate)
        }
        return result.sorted { $0.passRate > $1.passRate }
    }

    // MARK: - 蒸馏(注入模型,可测)

    /// 把候选蒸馏成纯提示 skill。`distill` 是注入的模型调用(prompt→文本),便于无网络单测。
    /// 蒸馏正文经 `sanitizePromptOnly` 净化;净化后没有任何要点行的候选直接跳过(不产生空壳 skill)。
    static func consolidate(
        candidates: [Candidate],
        distill: @Sendable (String) async -> String
    ) async -> [DistilledSkill] {
        var out: [DistilledSkill] = []
        for candidate in candidates {
            let examples = candidate.successes.prefix(6).enumerated().map { index, sample in
                "\(index + 1). 任务:\(sample.prompt.prefix(120))\n   结果:\(sample.summary.prefix(160))"
            }.joined(separator: "\n")
            let prompt = """
            下面是「\(candidate.title)」这类任务里**已成功交付**的若干真实案例。请把它们提炼成一份可复用的
            "专家要点 + 评审清单",供以后做同类任务直接参考:
            ## 专业要点
            （5–8 条做这类任务的关键经验/套路/易错点,每条一行,以「- 」开头）
            ## 评审清单
            （4–6 条交付前自检项,每条一行,以「- 」开头）
            **若这类任务靠一段可复用的脚本/生成器完成的**(如把声明式数据渲染成产物),再附:
            ## 生成脚本
            （把那个可复用生成器的完整代码放进围栏代码块——会自动过安全门,安全才保留;让以后同类任务直接复用、不必每次现写）
            成功案例:
            \(examples)
            """
            // **2026-06-27:不再无差别剥光,改过自动安全门**——灵枢自己来源的生成器,安全就保留(静默进化外围 skill)。
            let (body, keptGenerator) = safetyFilterCode(await distill(prompt))
            guard hasAnyBullet(body) else { continue }   // 净化后空壳不落盘
            // 实测通过率作质量分,封顶 0.85(低于人工策展 0.9,自动固化不抢策展优先级)。
            let qualityScore = min(0.85, max(0.5, candidate.passRate))
            let markdown = skillMarkdown(
                domain: candidate.domain,
                title: candidate.title,
                triggers: candidate.triggers,
                body: body,
                qualityScore: qualityScore,
                sampleCount: candidate.successes.count,
                hasGenerator: keptGenerator
            )
            out.append(.init(domain: candidate.domain, markdown: markdown, qualityScore: qualityScore, sampleCount: candidate.successes.count))
        }
        return out
    }

    // MARK: - 设计进化(Phase C:从历史 PPT 设计评分 + 反馈提炼可复用设计经验)

    /// 一次 PPT 的设计回放样本(评分 + 👍👎 + 审计抓到的失败点)。
    struct DesignSample: Equatable, Sendable {
        let prompt: String
        let score: Double      // 过程内/验收的设计质量分 0–1
        let liked: Bool?       // 用户 👍👎
        let issues: [String]   // 审计低分页的具体问题(失败点)——从失败里学
    }

    /// 从设计样本提炼可复用设计经验(纯文字,红线净化)。**显式纳入失败点**,让经验直击"上次为什么扣分"。
    /// 样本不足/净化后无要点 → nil。
    static func consolidateDesignInsights(
        samples: [DesignSample],
        minSamples: Int = 3,
        distill: @Sendable (String) async -> String
    ) async -> String? {
        guard samples.count >= minSamples else { return nil }
        let lines = samples.sorted { $0.score > $1.score }.prefix(12).map { s -> String in
            let fb = s.liked == true ? " 👍" : (s.liked == false ? " 👎" : "")
            let fails = s.issues.isEmpty ? "" : ";扣分点:" + s.issues.prefix(3).joined(separator: " / ")
            return "评分 \(String(format: "%.2f", s.score))\(fb) — \(s.prompt.prefix(60))\(fails)"
        }.joined(separator: "\n")
        let prompt = """
        下面是灵枢过去做 PPT 的设计评分案例(分越高=排版越专业,附每次的扣分点)。提炼 4–8 条**可复用的设计经验**:
        **标注「用户反馈:」的是用户亲眼看了产出物后给的纠正——最高优先级,必须各自提炼成一条不可违反的铁律**
        (例:用户说"深色底黑图标看不清"→「- 深色主题图标/图表元素一律用亮色,禁用近黑色」;用户说"图片无关"→
        「- 配图必须切题,抽象主题宁用图标/图表不配照片」)。其次从扣分点总结"下次怎么避免",再补高分案例的好做法。
        **纯文字经验,每条以「- 」开头,严禁写任何代码/脚本/命令。**
        案例:
        \(lines)
        """
        let body = sanitizePromptOnly(await distill(prompt))
        guard hasAnyBullet(body) else { return nil }
        return "# 设计经验(灵枢 dreaming 自固化,来自 \(samples.count) 次 PPT 的设计评分)\n\n\(body)\n"
    }

    // MARK: - 安全净化 + 组装(纯函数,可测)

    /// 红线净化:剥掉**一切围栏代码块**与标题含「脚本/script/代码/生成器」的小节——
    /// 保证落盘的自固化 skill 是纯提示、永不携带可自动执行的代码。
    static func sanitizePromptOnly(_ markdown: String) -> String {
        var kept: [String] = []
        var inFence = false
        var inScriptSection = false
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }   // 围栏代码整段丢
            if inFence { continue }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                inScriptSection = ["脚本", "script", "代码", "生成器", "generator"].contains { heading.contains($0) }
            }
            if inScriptSection { continue }
            kept.append(raw)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **安全门过滤(2026-06-27,替代无差别剥光)**:正文里的围栏代码块**逐块过 `LingShuSkillSafetyGate`**——
    /// 安全的**保留**(让灵枢从自己验证过的任务里长出来的 skill 能进化生成器,静默升级),扫出危险的才整块剥掉。
    /// 用户定调:skill 是可自由进化的外围,自动门把关即可、不需人工授权;只有**未审外部来源**(discover_skill)和
    /// **内核**才需人工门。灵枢自己来源的代码不是"未审来源"。返回净化后正文 + 是否保留了生成器代码。
    static func safetyFilterCode(_ markdown: String) -> (body: String, keptGenerator: Bool) {
        var kept: [String] = []
        var fenceOpen = ""
        var fenceBuffer: [String] = []
        var inFence = false
        var keptGenerator = false
        for raw in markdown.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    let code = fenceBuffer.joined(separator: "\n")
                    if LingShuSkillSafetyGate.scan(code).isSafe {   // 安全→连围栏一起保留
                        kept.append(fenceOpen); kept.append(contentsOf: fenceBuffer); kept.append(raw)
                        keptGenerator = true
                    }   // 危险→整块丢(保守)
                    fenceBuffer = []; fenceOpen = ""; inFence = false
                } else {
                    inFence = true; fenceOpen = raw
                }
                continue
            }
            if inFence { fenceBuffer.append(raw); continue }
            kept.append(raw)
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), keptGenerator)
    }

    /// 正文里是否还有至少一条要点行(净化后用于挡空壳)。
    static func hasAnyBullet(_ body: String) -> Bool {
        body.components(separatedBy: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("-") || t.hasPrefix("•") || t.hasPrefix("*")
        }
    }

    /// 组装可被 LingShuSkillLoader 解析的 skill markdown。`hasGenerator=true`(正文保留了过安全门的生成器)时
    /// **带上 `script_name`** → loader 把「## 生成脚本」挂成 bundledScript,让固化的 skill 自带可复用生成器(静默进化外围)。
    static func skillMarkdown(
        domain: String,
        title: String,
        triggers: [String],
        body: String,
        qualityScore: Double,
        sampleCount: Int,
        hasGenerator: Bool = false
    ) -> String {
        let scriptLine = hasGenerator ? "\nscript_name: generator.py" : ""
        return """
        ---
        id: dreamed-\(domain)
        title: \(title)（自固化）
        mission: 灵枢从 \(sampleCount) 个成功交付的同类任务离线固化的可复用经验(实测通过率约 \(Int((qualityScore * 100).rounded()))%）。\(hasGenerator ? "自带可复用生成器(已过安全门)。" : "")
        triggers: \(triggers.joined(separator: ","))\(scriptLine)
        ---

        \(body)
        """
    }
}
