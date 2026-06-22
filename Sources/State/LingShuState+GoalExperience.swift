import Foundation

/// 通用中枢 P4·**经验闭环**接线(见 [[LingShuGoalExperience]])。
/// 目标终态 → 蒸一条**结构化可复用经验**入持久库(与 P1 知识图谱事实并存:图谱供广义 recall_memory,这条供**确定性主动注入**)。
/// 新目标执行前 → 据相似度召回最相关历史经验,**注入执行引导**(driveAgentDelivery),让大脑复用成功打法/避开旧坑。
@MainActor
extension LingShuState {

    private static let goalExperiencesKey = "lingshu.goal.experiences"

    /// 持久化的目标经验库(跨重启;尾部截断,留最近 N 条)。
    func goalExperiences() -> [LingShuGoalExperience] {
        guard let data = UserDefaults.standard.data(forKey: Self.goalExperiencesKey),
              let list = try? JSONDecoder().decode([LingShuGoalExperience].self, from: data) else { return [] }
        return list
    }

    private func persistGoalExperiences(_ list: [LingShuGoalExperience]) {
        let capped = Array(list.suffix(200))
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: Self.goalExperiencesKey)
        }
    }

    func recordGoalExperience(_ exp: LingShuGoalExperience) {
        var list = goalExperiences()
        list.append(exp)
        persistGoalExperiences(list)
    }

    /// 召回与目标最相关的历史经验(供执行引导注入 / 测试)。
    func recallGoalExperiences(for objective: String, limit: Int = 2, excludingSourceRecordID: String? = nil) -> [LingShuGoalExperience] {
        LingShuGoalExperienceMatch.mostRelevant(goalExperiences(), to: objective, limit: limit, excludingSourceRecordID: excludingSourceRecordID)
    }

    /// 把相关历史经验拼进执行引导(无相关经验 → 返回 base 原样)。目标取 GoalSpec.objective,兜底用记录 prompt。
    func goalExperienceGuidance(base: String?, taskRecordID: String?) -> String {
        let objective = (goalSpec(for: taskRecordID)?.objective
            ?? taskExecutionRecords.first(where: { $0.id == taskRecordID })?.prompt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return base ?? "" }
        let relevant = recallGoalExperiences(for: objective, excludingSourceRecordID: taskRecordID)
        if !relevant.isEmpty {
            appendTrace(kind: .system, actor: "经验复用", title: "召回相关历史经验",
                        detail: relevant.map { "「\($0.objective.prefix(18))」→\($0.outcome)" }.joined(separator: " / "))
        }
        return LingShuGoalExperienceMatch.guidanceBlock(from: relevant, base: base)
    }

    /// **统一前置认知引导组装**(P1 目标 → P2 缺口 → P4 经验,逐层叠加)。主会话/自主走 driveAgentDelivery 用它;
    /// **派发隔离任务**也用它(经 initialMessages 注入)——否则派发任务收不到 GoalSpec/缺口/经验引导(此前的真 bug)。
    func assembledExecutionGuidance(base: String?, taskRecordID: String?) -> String {
        let goalGuidance = goalSpec(for: taskRecordID)?.executionGuidance(base: base) ?? base
        let gapGuidance = gapAnalysis(for: taskRecordID)?.executionGuidance(base: goalGuidance) ?? goalGuidance
        let expGuidance = goalExperienceGuidance(base: gapGuidance, taskRecordID: taskRecordID)
        // P6+ 模块变体:执行策略片段(运行时热切换槽)经【编译核心变体·组合器】与上面引导组合——
        // 默认 append(策略后置,行为同历史);可一键切 prepend(策略前置,给重视开头指令的大脑)/一键回退。
        // 基线策略片段为空时组合器优雅返回 expGuidance 原样(不改行为)。
        let strategy = executionStrategyAddendum()
        return activeGuidanceComposer().compose(experience: expGuidance, strategy: strategy)
    }

    /// 从任务记录蒸一条可复用教训(成功打法 / 要避开的坑 + 能力补齐复用线索)。
    func distilledGoalLesson(outcome: String, spec: LingShuGoalSpec, record rec: LingShuTaskExecutionRecord) -> String {
        var parts: [String] = []
        switch outcome {
        case "已完成", "已核验完成":
            let arts = rec.artifacts.map { ($0.location as NSString).lastPathComponent }.prefix(2)
            parts.append(arts.isEmpty ? "上次顺利做成" : "上次做成,产出:\(arts.joined(separator: "、"))")
        case "部分完成":
            parts.append("上次只部分完成" + (rec.summary.isEmpty ? "" : ":\(rec.summary.prefix(50))"))
        case "未达标", "失败":
            parts.append("上次没成" + (rec.summary.isEmpty ? "" : ":\(rec.summary.prefix(50))") + " —— 这次避开")
        default:
            parts.append("上次:\(outcome)")
        }
        if let attempts = rec.acquisitionAttempts, !attempts.isEmpty {
            let needUser = attempts.filter { $0.outcome == .needsUser }.map(\.capability)
            if !needUser.isEmpty { parts.append("需用户先提供:\(needUser.prefix(2).joined(separator: "、"))") }
            let reusable = attempts.filter { $0.outcome == .acquiredVerified }.map(\.capability)
            if !reusable.isEmpty { parts.append("已补齐可复用:\(reusable.prefix(2).joined(separator: "、"))") }
        }
        return parts.joined(separator: ";")
    }
}
