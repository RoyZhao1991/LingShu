import Foundation

/// skill 自发现 + 自安装(自进化 Phase 2,补"自主找最好 skill 自动装"老需求)。
///
/// 安全模型(用户已拍板;供应链红线见 [[skill-self-evolution]] 记忆):
/// - **纯提示 skill**(无 `## 生成脚本`)→ 零执行风险 → 直接装、热加载,自动可用。
/// - **带脚本 skill** → 双层门控:
///   ① 静态安全门 `LingShuSkillSafetyGate.scan`(挡 rm -rf/sudo/外联执行/读凭据…);过不了 → 拒装。
///   ② 过门后再调大模型做**风险审**(输出 RISK=none/low/high + 理由)。
///      - 明确无风险(none)→ 装(脚本仍走 run_command 既有审批,绝不静默执行)。
///      - 有风险(low/high/含糊)→ 装,但把脚本**隔离**:首次执行它必经用户审批(把 LLM 评估的风险点
///        摆给用户裁决),即便会话此前选过"完全授权"也强制弹一次。**绝不静默自动执行未审来源代码。**
///
/// 本类型只做**纯逻辑 + 隔离清单持久化**(可单测);联网搜候选、LLM 风险审、落盘热加载、审批弹窗
/// 由 `LingShuState+SkillDiscovery` 编排(复用 web_search / 无工具小会话 / reloadUserSkills / requestShellApproval)。
enum LingShuSkillAcquisition {

    /// 候选 skill 的分类(决定安装路径)。纯函数,可单测。
    enum Classification: Equatable {
        case promptOnly                        // 无脚本 → 直接装
        case scriptBlockedByGate([String])     // 带脚本但静态门拦下 → 拒装(命中的高危项)
        case scriptNeedsRiskReview(String)     // 带脚本且过静态门 → 交 LLM 风险审(原始脚本)
    }

    /// 风险审裁决(由模型自由文本解析而来)。
    enum RiskVerdict: Equatable {
        case safe                 // 明确无风险 → 直接装
        case risky([String])      // 有风险点 → 装但首次运行审批
    }

    /// 解析候选 markdown 并分类(静态门在此;LLM 风险审在调用方)。无法解析(无 title)返回 nil。
    static func classify(markdown: String, fallbackID: String) -> (skill: LingShuSkillLoader.LoadedSkill, kind: Classification)? {
        guard let loaded = LingShuSkillLoader.parse(markdown, fallbackID: fallbackID) else { return nil }
        guard let rawScript = LingShuSkillLoader.rawBundledScript(in: markdown) else {
            return (loaded, .promptOnly)
        }
        let verdict = LingShuSkillSafetyGate.scan(rawScript)
        if !verdict.isSafe { return (loaded, .scriptBlockedByGate(verdict.violations)) }
        return (loaded, .scriptNeedsRiskReview(rawScript))
    }

    /// 把 LLM 风险审的自由文本解析成裁决。**保守 fail-safe**:只有模型**明确判无风险**才放行自动装,
    /// 含糊/低/高一律按"有风险"走首次运行审批(未审来源代码,宁严勿松)。
    static func parseRiskVerdict(_ text: String) -> RiskVerdict {
        let lower = text.lowercased()
        let saysNone = lower.contains("risk=none") || lower.contains("风险=无") || lower.contains("无风险") || lower.contains("无明显风险")
        let saysLowOrHigh = lower.contains("risk=low") || lower.contains("risk=high") || lower.contains("高风险") || lower.contains("低风险")
        if saysNone && !saysLowOrHigh {
            return .safe
        }
        let points = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { line in
                let l = line.lowercased()
                return !l.hasPrefix("risk=") && !line.hasPrefix("风险=")
            }
        return .risky(points.isEmpty ? ["模型未给出具体风险点(保守要求首次运行审批)"] : Array(points.prefix(6)))
    }

    /// 候选择优:web_search 链接里 GitHub / star 等"采用信号"靠前排;没有硬信号就保持原序(保守)。
    /// 纯函数(只按 URL 文本启发式排序),可单测。
    static func rankCandidates(_ urls: [URL]) -> [URL] {
        func score(_ u: URL) -> Int {
            let s = u.absoluteString.lowercased()
            var n = 0
            if s.contains("github.com") || s.contains("githubusercontent.com") { n += 3 }
            if s.contains("raw.githubusercontent.com") { n += 1 }   // 直链可直接取,更优
            if s.contains("skill.md") || s.hasSuffix(".md") { n += 2 }
            if s.contains("awesome") { n += 1 }
            return n
        }
        return urls.enumerated()
            .sorted { (score($0.element), -$0.offset) > (score($1.element), -$1.offset) }
            .map(\.element)
    }

    // MARK: - 隔离清单(高风险脚本首次运行审批)持久化
    //
    // `directory` 仅测试注入用;生产用默认 Skills 目录(随 skill 落盘一起持久,survive 重启)。

    private static func quarantineURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".quarantine.json")
    }

    /// 读隔离清单:skillID → 风险点。
    static func quarantineMap(in directory: URL = LingShuSkillLoader.defaultDirectory) -> [String: [String]] {
        guard let data = try? Data(contentsOf: quarantineURL(in: directory)),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return map
    }

    /// 某 skill 是否被隔离(高风险待首次审批);返回其风险点。
    static func quarantinedRiskNotes(forSkillID id: String, in directory: URL = LingShuSkillLoader.defaultDirectory) -> [String]? {
        quarantineMap(in: directory)[id]
    }

    /// 把高风险脚本 skill 标记为隔离(首次运行其脚本必经审批)。
    static func setQuarantine(skillID: String, riskNotes: [String], in directory: URL = LingShuSkillLoader.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var map = quarantineMap(in: directory)
        map[skillID] = riskNotes
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: quarantineURL(in: directory), options: [.atomic]) }
    }

    /// 用户首次审批通过后解除隔离(此后该脚本走常规 run_command 审批,不再强制)。
    static func clearQuarantine(skillID: String, in directory: URL = LingShuSkillLoader.defaultDirectory) {
        var map = quarantineMap(in: directory)
        guard map.removeValue(forKey: skillID) != nil else { return }
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: quarantineURL(in: directory), options: [.atomic]) }
    }
}
