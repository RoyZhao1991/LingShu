import Foundation

/// 本机知识中枢·**dreaming 蒸馏高频本机知识进图谱**(②)。
///
/// 思路:被 `recall_local` 反复命中的本机内容 = 对你高价值。dreaming 空闲时把这些**高频内容蒸馏成离散事实**
/// `remember` 进长期记忆/知识图谱([[memory-v2-knowledge-graph]])→ 以后相关提问可直接从图谱召回(更快),
/// 图谱也越用越懂你。蒸馏过的清热度计数,避免重蒸。
///
/// 纯编排 + 注入 distill/remember 闭包(可单测,不依赖真模型/真图谱);生产侧由 State 注入 adapter 会话 + graph.remember。
enum LingShuLocalKnowledgeDistiller {
    /// 返回本次落库的事实数。`distill`=把一段内容→事实文本(每行一条);`remember`=把一条事实落进长期记忆。
    @discardableResult
    static func run(index: LingShuFileKnowledgeIndex,
                    minHits: Int = 3,
                    limit: Int = 5,
                    maxFactsPerItem: Int = 3,
                    distill: @Sendable (String) async -> String,
                    remember: @Sendable (String) async -> Void) async -> Int {
        let top = index.topRecalled(minHits: minHits, limit: limit)
        guard !top.isEmpty else { return 0 }
        var added = 0
        var done: [String] = []
        for item in top {
            let prompt = """
            从下面这段【我本机的资料】里,提炼最多 \(maxFactsPerItem) 条**可长期复用的离散事实**(陈述句,别写步骤/指令/客套),每行一条,只输出事实本身:

            \(item.text.prefix(1500))
            """
            let out = await distill(prompt)
            let facts = parseFacts(out, max: maxFactsPerItem)
            for fact in facts { await remember(fact); added += 1 }
            done.append(item.path)
        }
        index.clearHits(for: done)   // 蒸馏过清计数,免重蒸
        return added
    }

    /// 解析事实清单(纯逻辑):按行切,剥项目符号,丢太短的。
    static func parseFacts(_ raw: String, max: Int) -> [String] {
        let cleaned = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*·。.").union(.whitespaces)) }
            .filter { $0.count >= 6 }
        return Array(cleaned.prefix(max))
    }
}
