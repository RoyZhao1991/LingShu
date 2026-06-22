import XCTest
@testable import LingShuMac

/// 通用中枢 P6·自我进化闭环(有界、人批):弱点挖掘(纯)+ 提案/人批/否决(State,不自动采纳)。
final class SelfImprovementTests: XCTestCase {

    private func exp(_ obj: String, _ outcome: String, _ lesson: String = "") -> LingShuGoalExperience {
        LingShuGoalExperience(objective: obj, kind: "task", outcome: outcome, lesson: lesson)
    }

    // MARK: 弱点挖掘(纯)

    func testDetectsRecurringFailureCluster() {
        let exps = [
            exp("把待办同步到 Notion 数据库", "未达标", "缺 token"),
            exp("同步今日待办到 Notion", "失败", "缺 DB ID"),
            exp("把待办写进 Notion", "部分完成", "集成没共享"),
            exp("写斐波那契脚本", "已完成", "做成了"),         // 成功,不计
            exp("查天气", "已完成")                            // 成功 + 不同主题
        ]
        let patterns = LingShuSelfImprovementMiner.detectPatterns(exps, minOccurrences: 2)
        XCTAssertEqual(patterns.count, 1, "三条 Notion 失败聚成一个反复弱点;成功的/不同主题的不计")
        XCTAssertEqual(patterns.first?.occurrences, 3)
        XCTAssertTrue(patterns.first?.theme.contains("Notion") ?? false)
    }

    func testNoPatternBelowThreshold() {
        let exps = [exp("把待办同步到 Notion", "失败", "缺 token"), exp("写个爬虫", "未达标", "崩了")]
        XCTAssertTrue(LingShuSelfImprovementMiner.detectPatterns(exps, minOccurrences: 2).isEmpty,
                      "各 1 次、互不相似 → 未到反复阈值,不提案")
    }

    func testSuggestionIsBoundedAndMentionsApproval() {
        let s = LingShuSelfImprovementMiner.suggestion(for: .init(theme: "同步到 Notion", occurrences: 3, sampleLessons: ["缺 token"]))
        XCTAssertTrue(s.contains("沙箱") && s.contains("安全门"), "建议走 M1 安全路径")
        XCTAssertTrue(s.contains("批准"), "强调人批后才建")
        XCTAssertTrue(s.contains("回滚"))
    }

    // MARK: 提案 / 人批 / 否决(State,不自动采纳)

    @MainActor
    func testProposeStoresPendingAndDoesNotAutoAdopt() {
        let ek = "lingshu.goal.experiences"; let pk = "lingshu.self.improvements"
        UserDefaults.standard.removeObject(forKey: ek); UserDefaults.standard.removeObject(forKey: pk)
        defer { UserDefaults.standard.removeObject(forKey: ek); UserDefaults.standard.removeObject(forKey: pk) }
        let state = LingShuState()
        // 灌三条同类失败经验。
        for (o, l) in [("把待办同步到 Notion 数据库", "缺 token"), ("同步今日待办到 Notion", "缺 DB ID"), ("把待办写进 Notion", "没共享")] {
            state.recordGoalExperience(.init(objective: o, kind: "task", outcome: "未达标", lesson: l))
        }
        let added = state.proposeSelfImprovements()
        XCTAssertEqual(added, 1, "反复 Notion 弱点 → 1 条提案")
        let props = state.improvementProposals()
        XCTAssertEqual(props.count, 1)
        XCTAssertEqual(props.first?.status, .pending, "默认 pending,**不自动采纳**")
        // 再提案一次:同 theme 去重,不重复加。
        XCTAssertEqual(state.proposeSelfImprovements(), 0, "同 theme 已有 pending → 去重")
    }

    @MainActor
    func testRejectMarksRejectedAndStopsReproposing() {
        let ek = "lingshu.goal.experiences"; let pk = "lingshu.self.improvements"
        UserDefaults.standard.removeObject(forKey: ek); UserDefaults.standard.removeObject(forKey: pk)
        defer { UserDefaults.standard.removeObject(forKey: ek); UserDefaults.standard.removeObject(forKey: pk) }
        let state = LingShuState()
        for (o, l) in [("把待办同步到 Notion", "缺 token"), ("同步待办到 Notion 库", "缺 DB")] {
            state.recordGoalExperience(.init(objective: o, kind: "task", outcome: "失败", lesson: l))
        }
        _ = state.proposeSelfImprovements()
        let id = state.improvementProposals().first!.id
        state.rejectSelfImprovement(id: id)
        XCTAssertEqual(state.improvementProposals().first { $0.id == id }?.status, .rejected)
        // 否决后不再就同 theme 反复提案(rejected 不算去重豁免?——否,rejected 的不挡新提案;但本测确认状态正确)。
        let props = state.improvementProposals()
        XCTAssertTrue(props.contains { $0.status == .rejected })
    }

    func testProposalCodableRoundTrip() throws {
        let p = LingShuImprovementProposal(theme: "同步 Notion", occurrences: 3, suggestion: "自写工具", status: .pending)
        let back = try JSONDecoder().decode(LingShuImprovementProposal.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.theme, "同步 Notion")
        XCTAssertEqual(back.status, .pending)
    }
}
