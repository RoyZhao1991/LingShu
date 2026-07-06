import Foundation

/// 经验规则记忆：把"任务失败 → 被评审打回 → 如何修正"提炼成可复用的通用规则，
/// 写入语义库（kind=经验规则）。规划阶段召回相关规则注入——下次不再从零踩坑，
/// 让记忆从"流水账"长成"复利"。对应文章里有效记忆的完整路径：
/// 失败并记录 → 核实诊断 → 提炼为通用规则 → 下次直接查规则。
extension LingShuMemoryService {
    static let experienceRuleKind = "经验规则"

    /// 写入一条经验规则。同领域+规则去重靠语义库 upsert（title 即规则要点）。
    @discardableResult
    func rememberExperienceRule(domain: String, rule: String, source: String) -> Bool {
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedRule.count >= 6 else { return false }
        let title = String(trimmedRule.prefix(40))
        return semanticStore.remember(
            kind: Self.experienceRuleKind,
            title: title,
            content: "【领域：\(domain)】\(trimmedRule)（来源：\(source)）",
            tags: LingShuMemoryTextToolkit.taskTags(from: "\(domain) \(trimmedRule)") + ["rule"],
            importance: 0.85
        ) != nil
    }

    /// 召回与当前任务相关的经验规则（按语义近似），供规划阶段纳入考虑。
    /// 要求词面锚点，避免本地向量模型的幽灵相似度污染规划上下文。
    func recallExperienceRules(for prompt: String, limit: Int = 4) -> [String] {
        semanticStore.recall(query: prompt, limit: limit * 2)
            .filter { $0.entry.kind == Self.experienceRuleKind && $0.matchedBy.contains("全文") }
            .prefix(limit)
            .map { $0.entry.content }
    }

    /// 经验规则总数（供设置页展示记忆成长度）。
    var experienceRuleCount: Int {
        semanticStore.count(kind: Self.experienceRuleKind)
    }
}
