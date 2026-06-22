import Foundation

/// 通用中枢 P6·**自我进化闭环**(有界、人批)(纯类型 + 模式挖掘,可单测)。
///
/// 从 P4 经验库挖**反复失败/反复缺同一能力**的弱点 → 生成**有界改进提案**(自写工具/装技能/接连接器/调提示策略)。
/// **绝不自改核心 Swift**;提案默认 pending,**人批后**才经 M1(author_component 沙箱+安全门)真去建、可回滚。对应 #13。
/// 这里只放纯挖掘 + 提案类型;采纳由人触发、走既有 M1 安全路径(见 LingShuState+SelfImprovement)。
struct LingShuImprovementPattern: Sendable, Equatable {
    var theme: String            // 代表性目标/主题(簇的首条)
    var occurrences: Int         // 反复次数
    var sampleLessons: [String]  // 几条样本教训(供生成提案/给人看)
}

enum LingShuImprovementStatus: String, Codable, Sendable, Equatable {
    case pending    // 已提案,等人批
    case approved   // 人已批准 → 已派任务去建
    case rejected   // 人已否决
}

struct LingShuImprovementProposal: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var theme: String
    var occurrences: Int
    var suggestion: String       // 具体建议做什么(有界:自写工具/装技能/接连接器/调提示)
    var status: LingShuImprovementStatus
    var at: Date

    init(theme: String, occurrences: Int, suggestion: String, status: LingShuImprovementStatus = .pending, at: Date = Date()) {
        self.id = "imp-\(UUID().uuidString.prefix(8))"
        self.theme = theme
        self.occurrences = occurrences
        self.suggestion = suggestion
        self.status = status
        self.at = at
    }
}

enum LingShuSelfImprovementMiner {
    /// 从经验库挖反复弱点:只看**非成功**经验(失败/未达标/部分完成),按目标相似度贪心聚类,
    /// 簇内 ≥ minOccurrences 条 = 一个反复弱点(灵枢老在这类目标上栽 → 值得自我改进)。纯函数。
    static func detectPatterns(_ experiences: [LingShuGoalExperience], minOccurrences: Int = 2,
                               clusterThreshold: Double = 0.4) -> [LingShuImprovementPattern] {
        let failures = experiences.filter { !$0.succeeded }
        var clusters: [[LingShuGoalExperience]] = []
        for f in failures {
            if let i = clusters.firstIndex(where: { LingShuGoalExperienceMatch.relevance($0[0].objective, f.objective) >= clusterThreshold }) {
                clusters[i].append(f)
            } else {
                clusters.append([f])
            }
        }
        return clusters
            .filter { $0.count >= minOccurrences }
            .sorted { $0.count > $1.count }
            .map { c in
                LingShuImprovementPattern(theme: c[0].objective, occurrences: c.count,
                                          sampleLessons: Array(c.prefix(3).map(\.lesson)))
            }
    }

    /// 据弱点拟一条**有界**改进建议(模板;State 层可再用模型润色)。强调走 M1 安全路径、人批后建。
    static func suggestion(for p: LingShuImprovementPattern) -> String {
        let lessons = p.sampleLessons.filter { !$0.isEmpty }.prefix(2).joined(separator: ";")
        return "灵枢在「\(p.theme.prefix(40))」这类目标上已反复受挫 \(p.occurrences) 次" +
            (lessons.isEmpty ? "" : "(\(lessons))") +
            "。建议补齐对应能力:自写工具 / 装现成技能 / 接连接器(经沙箱+安全门),你批准后我去建,采纳后可禁用回滚。"
    }
}
