import Foundation

/// 通用中枢 P4·**经验闭环**·目标经验(可复用决策资产)(纯类型 + 相关性打分 + 引导格式化,可单测)。
///
/// P1 已把目标终态沉淀成知识图谱里的「经验」事实(被动,靠模型自己 recall_memory 才用得上)。
/// P4 把它升级成**主动复用闭环**:新目标到来时,据**目标相似度**召回最相关的历史经验,**注入执行引导**——
/// 让大脑复用上次的成功打法、避开上次踩过的坑(尤其失败/部分完成的教训)。
/// 相似度用**字符二元组 Jaccard**(中文友好、无需嵌入基建的务实启发式)。
struct LingShuGoalExperience: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let objective: String
    let kind: String      // task/question/interaction/…(GoalSpec.kind.rawValue)
    let outcome: String   // 已完成/已核验完成/已直接回答/未达标/部分完成/失败
    let lesson: String    // 可复用的一句话经验:成功打法 or 要避开的坑
    let at: Date
    let sourceRecordID: String?

    init(objective: String, kind: String, outcome: String, lesson: String, at: Date = Date(), sourceRecordID: String? = nil) {
        self.id = "exp-\(UUID().uuidString.prefix(8))"
        self.objective = objective
        self.kind = kind
        self.outcome = outcome
        self.lesson = lesson
        self.at = at
        self.sourceRecordID = sourceRecordID
    }

    var succeeded: Bool { outcome == "已完成" || outcome == "已核验完成" || outcome == "已直接回答" }
}

enum LingShuGoalExperienceMatch {
    struct Ranked: Equatable {
        var experience: LingShuGoalExperience
        var relevance: Double
        var freshness: Double
        var outcomeWeight: Double
        var score: Double
    }

    /// 字符二元组 Jaccard 相似度(中文友好,纯启发式)。0…1。
    static func relevance(_ a: String, _ b: String) -> Double {
        let ga = bigrams(a), gb = bigrams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        let union = ga.union(gb).count
        return union == 0 ? 0 : Double(ga.intersection(gb).count) / Double(union)
    }

    /// 取字符二元组(只留字母/数字/CJK,去空白标点;长度 <2 退化为单字集合)。
    static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
        if chars.count < 2 { return Set(chars.map(String.init)) }
        var g = Set<String>()
        for i in 0..<(chars.count - 1) { g.insert(String(chars[i...(i + 1)])) }
        return g
    }

    /// 经验综合分:相关度 × 新鲜度 × 结果权重。
    /// 失败/部分完成仍有价值,但会自然衰减;普通直答的经验权重最低,避免把一次问答永久推到前台。
    static func ranked(
        _ experiences: [LingShuGoalExperience],
        to objective: String,
        now: Date = Date(),
        threshold: Double = 0.2,
        scoreThreshold: Double = 0.04,
        excludingSourceRecordID: String? = nil
    ) -> [Ranked] {
        experiences
            .filter { exp in
                guard let excludingSourceRecordID else { return true }
                return exp.sourceRecordID != excludingSourceRecordID
            }
            .compactMap { exp -> Ranked? in
                let r = relevance(exp.objective, objective)
                guard r >= threshold else { return nil }
                let f = freshnessWeight(exp, now: now)
                let w = outcomeWeight(exp)
                let s = r * f * w
                guard s >= scoreThreshold else { return nil }
                return .init(experience: exp, relevance: r, freshness: f, outcomeWeight: w, score: s)
            }
            .sorted {
                if abs($0.score - $1.score) > 0.000001 { return $0.score > $1.score }
                if abs($0.relevance - $1.relevance) > 0.000001 { return $0.relevance > $1.relevance }
                return $0.experience.at > $1.experience.at
            }
    }

    /// 取与目标最相关的经验:过阈值 + 按综合分降序 + 限量。仅按 sourceRecordID 排除当前任务自身,不误伤完全相同的历史目标。
    static func mostRelevant(_ experiences: [LingShuGoalExperience], to objective: String,
                             limit: Int = 2,
                             threshold: Double = 0.2,
                             scoreThreshold: Double = 0.04,
                             now: Date = Date(),
                             excludingSourceRecordID: String? = nil) -> [LingShuGoalExperience] {
        ranked(experiences, to: objective, now: now, threshold: threshold, scoreThreshold: scoreThreshold,
               excludingSourceRecordID: excludingSourceRecordID)
            .prefix(limit)
            .map(\.experience)
    }

    /// 持久库保留策略:可复用任务经验保留更久;普通直答只短期保留。
    static func retained(_ experiences: [LingShuGoalExperience], now: Date = Date()) -> [LingShuGoalExperience] {
        experiences.filter { exp in
            let days = max(0, now.timeIntervalSince(exp.at) / 86_400)
            if exp.outcome == "已直接回答" { return days <= 14 }
            if exp.outcome == "失败" || exp.outcome == "未达标" || exp.outcome == "部分完成" { return days <= 120 }
            return days <= 180
        }
    }

    /// 注入执行引导的「相关历史经验」块(无相关经验 → 返回 base 原样,不加压)。
    static func guidanceBlock(from experiences: [LingShuGoalExperience], base: String?) -> String {
        guard !experiences.isEmpty else { return base ?? "" }
        var lines = ["【相关历史经验(你做过类似目标——复用成功打法、别重蹈覆辙)】"]
        for e in experiences {
            lines.append("- 目标「\(e.objective.prefix(40))」→ \(e.outcome):\(e.lesson)")
        }
        let block = lines.joined(separator: "\n")
        guard let b = base?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return block }
        return b + "\n\n" + block
    }

    private static func freshnessWeight(_ experience: LingShuGoalExperience, now: Date, halfLifeDays: Double = 45) -> Double {
        let days = max(0, now.timeIntervalSince(experience.at) / 86_400)
        return max(0.05, pow(0.5, days / halfLifeDays))
    }

    private static func outcomeWeight(_ experience: LingShuGoalExperience) -> Double {
        switch experience.outcome {
        case "已核验完成": return 1.0
        case "已完成": return 0.92
        case "部分完成": return 0.86
        case "未达标", "失败": return 0.82
        case "已直接回答": return 0.55
        default: return 0.70
        }
    }
}
