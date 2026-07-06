import XCTest
@testable import LingShuMac

/// 通用中枢 P4·经验闭环:相似度打分 + 召回 + 引导格式化(纯逻辑)+ 库存取/主动召回(State)。
final class GoalExperienceTests: XCTestCase {

    // MARK: 相似度 + 召回(纯)

    func testRelevanceHighForSimilarLowForUnrelated() {
        let sim = LingShuGoalExperienceMatch.relevance("把今天的待办同步到我的 Notion 数据库", "把待办事项同步到 Notion")
        let dis = LingShuGoalExperienceMatch.relevance("把待办同步到 Notion", "写一个斐波那契 Python 脚本")
        XCTAssertGreaterThan(sim, 0.2, "同类目标相似度高")
        XCTAssertLessThan(dis, 0.1, "无关目标相似度低")
        XCTAssertGreaterThan(sim, dis)
    }

    func testMostRelevantFiltersSortsAndExcludesSelf() {
        let exps = [
            LingShuGoalExperience(objective: "把待办同步到 Notion 数据库", kind: "task", outcome: "未达标", lesson: "缺 token"),
            LingShuGoalExperience(objective: "写斐波那契脚本", kind: "task", outcome: "已完成", lesson: "做成了"),
            LingShuGoalExperience(objective: "同步今日待办到 Notion", kind: "task", outcome: "部分完成", lesson: "缺 DB ID")
        ]
        let hits = LingShuGoalExperienceMatch.mostRelevant(exps, to: "把今天的待办同步到我的 Notion", limit: 2)
        XCTAssertEqual(hits.count, 2, "过阈值的相关经验,限 2 条")
        XCTAssertTrue(hits.allSatisfy { $0.objective.contains("Notion") }, "召回的都是 Notion 同类,不召回斐波那契")
    }

    func testMostRelevantRecallsIdenticalHistoricalObjective() {
        let exps = [LingShuGoalExperience(objective: "完全一样的目标", kind: "task", outcome: "已完成", lesson: "历史经验")]
        let hits = LingShuGoalExperienceMatch.mostRelevant(exps, to: "完全一样的目标")
        XCTAssertEqual(hits.first?.lesson, "历史经验", "文字完全相同的历史目标也应该召回,否则会错过最有价值的复盘")
    }

    func testMostRelevantExcludesSameSourceRecordOnly() {
        let exps = [
            LingShuGoalExperience(objective: "同步 Notion", kind: "task", outcome: "未达标", lesson: "当前记录", sourceRecordID: "rec-current"),
            LingShuGoalExperience(objective: "同步 Notion", kind: "task", outcome: "未达标", lesson: "历史记录", sourceRecordID: "rec-old")
        ]
        let hits = LingShuGoalExperienceMatch.mostRelevant(exps, to: "同步 Notion", excludingSourceRecordID: "rec-current")
        XCTAssertEqual(hits.map(\.lesson), ["历史记录"], "只排除同一任务记录自身,不排除相同目标的历史记录")
    }

    func testFreshExperienceOutranksStaleExperience() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = LingShuGoalExperience(objective: "生成灵枢汇报 PPT", kind: "task", outcome: "已核验完成",
                                          lesson: "很久以前的打法", at: now.addingTimeInterval(-120 * 86_400))
        let fresh = LingShuGoalExperience(objective: "生成灵枢汇报 PPT", kind: "task", outcome: "已完成",
                                          lesson: "最近的打法", at: now.addingTimeInterval(-2 * 86_400))
        let hits = LingShuGoalExperienceMatch.mostRelevant([stale, fresh], to: "生成灵枢汇报 PPT", now: now)
        XCTAssertEqual(hits.first?.lesson, "最近的打法", "同等相关时新经验应优先")
    }

    func testDirectAnswerExperienceExpiresSooner() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDirect = LingShuGoalExperience(objective: "介绍一下灵枢", kind: "interaction", outcome: "已直接回答",
                                              lesson: "一次普通问答", at: now.addingTimeInterval(-20 * 86_400))
        let oldTask = LingShuGoalExperience(objective: "生成灵枢汇报 PPT", kind: "task", outcome: "未达标",
                                            lesson: "缺演示稿", at: now.addingTimeInterval(-20 * 86_400))
        let retained = LingShuGoalExperienceMatch.retained([oldDirect, oldTask], now: now)
        XCTAssertFalse(retained.contains(oldDirect), "普通直答经验只短期保留")
        XCTAssertTrue(retained.contains(oldTask), "任务失败/部分完成经验保留更久,用于避坑")
    }

    func testGuidanceBlockFormatAndPassthrough() {
        XCTAssertEqual(LingShuGoalExperienceMatch.guidanceBlock(from: [], base: "技能提示"), "技能提示", "无经验→原样返回 base")
        let exps = [LingShuGoalExperience(objective: "同步 Notion", kind: "task", outcome: "未达标", lesson: "缺 token,先问用户")]
        let g = LingShuGoalExperienceMatch.guidanceBlock(from: exps, base: "技能提示")
        XCTAssertTrue(g.hasPrefix("技能提示"))
        XCTAssertTrue(g.contains("相关历史经验"))
        XCTAssertTrue(g.contains("缺 token,先问用户"))
        XCTAssertTrue(LingShuGoalExperienceMatch.guidanceBlock(from: exps, base: nil).contains("相关历史经验"))
    }

    func testOldExperienceWithoutSourceRecordIDDecodesNil() throws {
        let json = #"{"id":"exp-old","objective":"同步 Notion","kind":"task","outcome":"未达标","lesson":"缺 token","at":0}"#
        let exp = try JSONDecoder().decode(LingShuGoalExperience.self, from: Data(json.utf8))
        XCTAssertNil(exp.sourceRecordID, "旧版本经验库没有 sourceRecordID 也要能向后兼容解码")
    }

    // MARK: 库存取 + 主动召回(State,闭环)

    @MainActor
    func testSinkThenRecallClosesLoop() {
        let key = "lingshu.goal.experiences"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()

        // 沉淀一条失败经验(上次同类目标因缺 token 没成)。
        state.recordGoalExperience(.init(objective: "把待办同步到我的 Notion 数据库", kind: "task",
                                         outcome: "未达标", lesson: "缺 Notion token,先问用户再做"))
        // 新的同类目标 → 主动召回到这条经验。
        let recalled = state.recallGoalExperiences(for: "帮我把今天的待办同步到 Notion")
        XCTAssertEqual(recalled.first?.lesson, "缺 Notion token,先问用户再做", "同类新目标主动召回历史经验=闭环成立")
        // 注入执行引导:把经验拼进去。
        let guidance = state.goalExperienceGuidance(base: "基础提示", taskRecordID: nil)
        XCTAssertEqual(guidance, "基础提示", "taskRecordID 为空(无目标)→ 不注入,原样返回")
    }

    /// 锁死"派发任务也拿到前置引导"的回归:派发不走 driveAgentDelivery,改用 assembledExecutionGuidance
    /// 经 initialMessages 注入;这条直接验组装结果**同时含 P1 目标 + P4 历史经验**(之前的真 bug:派发收不到这些引导)。
    @MainActor
    func testAssembledGuidanceCoversGoalAndExperienceForDispatch() {
        let key = "lingshu.goal.experiences"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        state.recordGoalExperience(.init(objective: "把待办同步到 Notion 数据库", kind: "task",
                                         outcome: "未达标", lesson: "缺 token,先问用户", sourceRecordID: "old-rec"))
        let rid = state.createTaskExecutionRecord(for: "帮我把今天的待办同步到我的 Notion")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        state.bindGoalSpec(.init(objective: "把今日待办同步到 Notion", kind: .task, successCriteria: ["写入成功"]), to: rid)

        let g = state.assembledExecutionGuidance(base: nil, taskRecordID: rid)
        XCTAssertTrue(g.contains("本次目标"), "派发任务用的统一引导必须含 P1 目标引导")
        XCTAssertTrue(g.contains("相关历史经验"), "也必须含 P4 历史经验(此前派发漏注入的真 bug)")
        XCTAssertTrue(g.contains("缺 token,先问用户"))
    }

    @MainActor
    func testGuidanceInjectsForRecordObjective() {
        let key = "lingshu.goal.experiences"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key); }
        let state = LingShuState()
        state.recordGoalExperience(.init(objective: "把待办同步到 Notion 数据库", kind: "task",
                                         outcome: "未达标", lesson: "缺 token,先问用户", sourceRecordID: "old-record"))
        let rid = state.createTaskExecutionRecord(for: "帮我把今天的待办同步到我的 Notion")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        let guidance = state.goalExperienceGuidance(base: "基础提示", taskRecordID: rid)
        XCTAssertTrue(guidance.contains("相关历史经验"), "同类新目标执行前注入历史经验")
        XCTAssertTrue(guidance.contains("缺 token,先问用户"))
    }

    @MainActor
    func testFailedTerminalTaskSinksReusableExperienceRule() {
        let key = "lingshu.goal.experiences"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let state = LingShuState()
        let marker = "rule-\(UUID().uuidString)"
        let ruleCountBefore = state.memoryService.experienceRuleCount
        var record = LingShuTaskExecutionRecord(
            id: "record-\(marker)",
            title: "失败经验沉淀",
            prompt: "生成报告并验收",
            status: .running,
            summary: "验收打回 \(marker)",
            participants: [],
            createdAt: Date(),
            updatedAt: Date(),
            messages: []
        )
        record.goalSpec = LingShuGoalSpec(
            objective: "生成报告并通过验收 \(marker)",
            kind: .task,
            successCriteria: ["报告存在", "验收通过"]
        )
        state.taskExecutionRecords = [record]

        state.rememberGoalExperienceIfNeeded(recordID: record.id, status: .failed)

        XCTAssertEqual(state.goalExperiences().last?.sourceRecordID, record.id, "失败终态必须进入结构化经验库")
        XCTAssertGreaterThanOrEqual(state.memoryService.experienceRuleCount, ruleCountBefore + 1, "失败/打回类终态必须同步沉淀为经验规则")
    }

    @MainActor
    func testMemoryDashboardStatsBackfillsTerminalHotAndColdRecords() {
        let key = "lingshu.goal.experiences"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let state = LingShuState()
        let marker = "backfill-\(UUID().uuidString)"
        var completed = LingShuTaskExecutionRecord(
            id: "hot-\(marker)",
            title: "已完成任务",
            prompt: "生成材料",
            status: .completed,
            summary: "已完成 \(marker)",
            participants: [],
            createdAt: Date().addingTimeInterval(-60),
            updatedAt: Date().addingTimeInterval(-50),
            messages: []
        )
        completed.goalSpec = LingShuGoalSpec(
            objective: "生成材料 \(marker)",
            kind: .task,
            successCriteria: ["材料已生成"]
        )
        var failed = LingShuTaskExecutionRecord(
            id: "cold-\(marker)",
            title: "未达标任务",
            prompt: "同步外部系统",
            status: .needsRevision,
            summary: "被验收打回 \(marker)",
            participants: [],
            createdAt: Date().addingTimeInterval(-30),
            updatedAt: Date().addingTimeInterval(-20),
            messages: []
        )
        failed.goalSpec = LingShuGoalSpec(
            objective: "同步外部系统 \(marker)",
            kind: .task,
            successCriteria: ["外部系统状态已更新"]
        )
        state.taskExecutionRecords = [completed]
        state.archivedTaskExecutionRecords = [failed]

        let result = state.reconcileExperienceArtifactsFromRecords(maxGoalExperiences: 10, maxRules: 10)
        let stats = state.memoryDashboardStats()

        XCTAssertEqual(result.goalExperiencesAdded, 2, "热记录和冷备终态记录都应能回填结构化经验")
        XCTAssertGreaterThanOrEqual(result.rulesAdded, 1, "未达标/失败类记录应回填经验规则")
        XCTAssertEqual(stats.hotTaskRecords, 1)
        XCTAssertEqual(stats.coldTaskRecords, 1)
        XCTAssertGreaterThanOrEqual(stats.goalExperiences, 2)
        XCTAssertGreaterThanOrEqual(stats.experienceAssets, 2)
    }
}
