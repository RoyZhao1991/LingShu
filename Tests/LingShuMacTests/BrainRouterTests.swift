import XCTest
@testable import LingShuMac

/// 当前主脑复杂度画像:纯复杂度评分仍可测,运行时不再切换不同模型端点。
final class BrainRouterTests: XCTestCase {

    // MARK: 理想档(复杂度打分,纯)

    func testDesiredTierByComplexity() {
        // 简单问答 → 弱。
        XCTAssertEqual(LingShuBrainRouter.desiredTier(.init(kind: .question)), .weak)
        // 普通 task(+2)带 1 约束 → 中。
        XCTAssertEqual(LingShuBrainRouter.desiredTier(.init(kind: .task, constraintCount: 0)), .medium)
        // 复杂 task:多约束 + 多标准 + 阻断缺口 → 强。
        XCTAssertEqual(LingShuBrainRouter.desiredTier(
            .init(kind: .task, constraintCount: 3, criteriaCount: 2, hasBlockingGap: true)), .strong)
    }

    func testEscalationBumpsTier() {
        let base = LingShuBrainRoutingSignals(kind: .question)   // 本来弱
        XCTAssertEqual(LingShuBrainRouter.desiredTier(base), .weak)
        var esc = base; esc.escalationCount = 1                  // 失败重试一次 → 抬档
        XCTAssertEqual(LingShuBrainRouter.desiredTier(esc), .medium)
        esc.escalationCount = 2
        XCTAssertEqual(LingShuBrainRouter.desiredTier(esc), .strong)
    }

    // MARK: 降级(据可用档)

    func testResolveDegradesToAvailableBelowDesired() {
        // 想要强,只配了弱+中 → 降到中(≤强 的最高)。
        XCTAssertEqual(LingShuBrainRouter.resolve(desired: .strong, available: [.weak, .medium]), .medium)
        // 想要中,只配了强 → 没有 ≤中 的,退用最低可用=强。
        XCTAssertEqual(LingShuBrainRouter.resolve(desired: .medium, available: [.strong]), .strong)
        // 想要弱,配了三档 → 弱(精确命中)。
        XCTAssertEqual(LingShuBrainRouter.resolve(desired: .weak, available: [.weak, .medium, .strong]), .weak)
        // 没配多脑(available 空)→ 返回理想档(上层落到当前单脑)。
        XCTAssertEqual(LingShuBrainRouter.resolve(desired: .strong, available: []), .strong)
    }

    func testRouteOneShot() {
        let s = LingShuBrainRoutingSignals(kind: .task, constraintCount: 3, criteriaCount: 2, hasBlockingGap: true)
        XCTAssertEqual(LingShuBrainRouter.route(s, available: [.weak, .medium]), .medium, "想要强但只配弱中→降级中")
    }

    func testControlPlaneRolesHaveBoundedRoutingProfiles() {
        XCTAssertEqual(LingShuBrainRouter.desiredTier(LingShuControlPlaneRole.triage.defaultSignals), .weak)
        XCTAssertEqual(LingShuBrainRouter.desiredTier(LingShuControlPlaneRole.goalSpec.defaultSignals), .medium)
        XCTAssertEqual(LingShuBrainRouter.desiredTier(LingShuControlPlaneRole.deliveryReview.defaultSignals), .strong)
        XCTAssertLessThanOrEqual(LingShuControlPlaneRole.triage.timeoutSeconds, 6)
        XCTAssertLessThanOrEqual(LingShuControlPlaneRole.acceptancePlanner.timeoutSeconds, 8)
    }

    // MARK: State 层:旧配置兼容 + 单主脑

    @MainActor
    func testLegacyTierConfigIsIgnoredInSingleMainBrainMode() {
        let key = "lingshu.brain.tiers"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()

        XCTAssertTrue(state.availableBrainTiers().isEmpty)
        _ = state.tierModelAdapter(.strong)

        // 当前版本不支持多脑协同:旧配置入口只做清理/兼容,不会产生可用档。
        state.setBrainTierModel(.weak, provider: "deepseek", model: "ds", endpoint: "https://w", apiKey: "k")
        state.setBrainTierModel(.strong, provider: "openai", model: "gpt", endpoint: "https://s", apiKey: "k2")
        XCTAssertTrue(state.availableBrainTiers().isEmpty)
        state.setBrainTierModel(.weak, provider: "", model: "", endpoint: "", apiKey: "")
        XCTAssertTrue(state.availableBrainTiers().isEmpty)
    }

    @MainActor
    func testRouteBrainTierFromRecordComplexity() {
        let key = "lingshu.brain.tiers"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "复杂任务")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        // 绑一个复杂 GoalSpec(多约束+多标准)→ 画像为 strong;执行仍由当前主脑处理。
        state.bindGoalSpec(.init(objective: "复杂", kind: .task, constraints: ["a", "b", "c"],
                                 successCriteria: ["x", "y"]), to: rid)
        XCTAssertEqual(state.routeBrainTier(taskRecordID: rid), .strong)
    }
}
