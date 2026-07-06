import Foundation

struct LingShuMemoryDashboardStats: Equatable {
    var graphNodes: Int
    var goalExperiences: Int
    var experienceRules: Int
    var pendingExperienceBackfill: Int
    var hotTaskRecords: Int
    var coldTaskRecords: Int

    var retainedTaskRecords: Int { hotTaskRecords + coldTaskRecords }
    var experienceAssets: Int { goalExperiences + experienceRules }
}

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
        let retained = LingShuGoalExperienceMatch.retained(list)
        let capped = Array(retained.suffix(200))
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: Self.goalExperiencesKey)
        }
    }

    func recordGoalExperience(_ exp: LingShuGoalExperience) {
        var list = goalExperiences()
        if let existing = list.firstIndex(where: {
            $0.objective == exp.objective &&
            $0.kind == exp.kind &&
            $0.outcome == exp.outcome &&
            $0.lesson == exp.lesson &&
            $0.sourceRecordID == exp.sourceRecordID
        }) {
            list.remove(at: existing)
        }
        list.append(exp)
        persistGoalExperiences(list)
    }

    func clearGoalExperiences() {
        UserDefaults.standard.removeObject(forKey: Self.goalExperiencesKey)
    }

    func memoryDashboardStats() -> LingShuMemoryDashboardStats {
        .init(
            graphNodes: knowledgeGraph.count,
            goalExperiences: goalExperiences().count,
            experienceRules: memoryService.experienceRuleCount,
            pendingExperienceBackfill: pendingExperienceBackfillCount(),
            hotTaskRecords: taskExecutionRecords.count,
            coldTaskRecords: archivedTaskExecutionRecords.count
        )
    }

    func pendingExperienceBackfillCount() -> Int {
        let existingSources = Set(goalExperiences().compactMap(\.sourceRecordID))
        return experienceBackfillCandidates().filter { !existingSources.contains($0.id) }.count
    }

    /// 历史回填：把已有任务记录中带 GoalSpec 的交付终态补成结构化经验。
    /// 只看 typed status / GoalSpec，不看关键词；排除普通直答，避免聊天内容把经验库冲脏。
    @discardableResult
    func reconcileExperienceArtifactsFromRecords(maxGoalExperiences: Int = 200, maxRules: Int = 80) -> (goalExperiencesAdded: Int, rulesAdded: Int) {
        let candidates = experienceBackfillCandidates()
        guard !candidates.isEmpty else { return (0, 0) }

        var existingSources = Set(goalExperiences().compactMap(\.sourceRecordID))
        var addedExperiences = 0
        let selected = Array(candidates.prefix(maxGoalExperiences)).sorted { $0.updatedAt < $1.updatedAt }
        for record in selected where !existingSources.contains(record.id) {
            guard let spec = record.goalSpec,
                  let outcome = Self.experienceOutcome(for: record.status)
            else { continue }
            recordGoalExperience(.init(
                objective: spec.objective,
                kind: spec.kind.rawValue,
                outcome: outcome,
                lesson: distilledGoalLesson(outcome: outcome, spec: spec, record: record),
                at: record.updatedAt,
                sourceRecordID: record.id
            ))
            existingSources.insert(record.id)
            addedExperiences += 1
        }

        let ruleCountBefore = memoryService.experienceRuleCount
        let ruleCandidates = candidates
            .filter { record in
                guard let outcome = Self.experienceOutcome(for: record.status) else { return false }
                return Self.shouldPersistExperienceRule(outcome: outcome)
            }
            .prefix(maxRules)
        for record in ruleCandidates {
            guard let spec = record.goalSpec,
                  let outcome = Self.experienceOutcome(for: record.status)
            else { continue }
            let lesson = distilledGoalLesson(outcome: outcome, spec: spec, record: record)
            memoryService.rememberExperienceRule(domain: spec.kind.rawValue, rule: lesson, source: record.id)
        }
        let addedRules = max(0, memoryService.experienceRuleCount - ruleCountBefore)
        return (addedExperiences, addedRules)
    }

    private func experienceBackfillCandidates() -> [LingShuTaskExecutionRecord] {
        taskExecutionRecordLookup
            .filter { record in
                guard record.goalSpec != nil,
                      let outcome = Self.experienceOutcome(for: record.status),
                      outcome != "已直接回答"
                else { return false }
                return true
            }
            .sorted { $0.updatedAt > $1.updatedAt }
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

    nonisolated static func experienceOutcome(for status: LingShuTaskExecutionStatus) -> String? {
        switch status {
        case .completed: return "已完成"
        case .verified: return "已核验完成"
        case .answered: return "已直接回答"
        case .needsRevision: return "未达标"
        case .partial: return "部分完成"
        case .failed: return "失败"
        default: return nil
        }
    }

    nonisolated static func shouldPersistExperienceRule(outcome: String) -> Bool {
        outcome == "未达标" || outcome == "部分完成" || outcome == "失败"
    }
}
