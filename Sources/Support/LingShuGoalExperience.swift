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

    /// 取与目标最相关的经验:过阈值 + 按相关性降序 + 限量。仅按 sourceRecordID 排除当前任务自身,不误伤完全相同的历史目标。
    static func mostRelevant(_ experiences: [LingShuGoalExperience], to objective: String,
                             limit: Int = 2, threshold: Double = 0.2, excludingSourceRecordID: String? = nil) -> [LingShuGoalExperience] {
        experiences
            .filter { exp in
                guard let excludingSourceRecordID else { return true }
                return exp.sourceRecordID != excludingSourceRecordID
            }
            .map { ($0, relevance($0.objective, objective)) }
            .filter { $0.1 >= threshold }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
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
}
