import XCTest
@testable import LingShuMac

/// 通用中枢 P5·强/中/弱脑分层:复杂度→理想档(纯)+ 据可用档降级 + State 层配置/路由。
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

    // MARK: State 层:配置 + 路由 + 单脑回退

    @MainActor
    func testTierConfigStoreAndRoutingFallback() {
        let key = "lingshu.brain.tiers"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()

        // 未配多脑 → 可用档为空,路由照算但落回当前单脑(tierModelAdapter 不崩、返回当前脑)。
        XCTAssertTrue(state.availableBrainTiers().isEmpty)
        _ = state.tierModelAdapter(.strong)   // 不崩(回退当前脑)

        // 配两档 → 可用档反映出来。
        state.setBrainTierModel(.weak, provider: "deepseek", model: "ds", endpoint: "https://w", apiKey: "k")
        state.setBrainTierModel(.strong, provider: "openai", model: "gpt", endpoint: "https://s", apiKey: "k2")
        XCTAssertEqual(state.availableBrainTiers(), [.weak, .strong])
        // 清除一档。
        state.setBrainTierModel(.weak, provider: "", model: "", endpoint: "", apiKey: "")
        XCTAssertEqual(state.availableBrainTiers(), [.strong])
    }

    @MainActor
    func testRouteBrainTierFromRecordComplexity() {
        let key = "lingshu.brain.tiers"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        state.setBrainTierModel(.weak, provider: "p", model: "m", endpoint: "https://w", apiKey: "k")
        state.setBrainTierModel(.medium, provider: "p", model: "m", endpoint: "https://m", apiKey: "k")
        let rid = state.createTaskExecutionRecord(for: "复杂任务")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        // 绑一个复杂 GoalSpec(多约束+多标准)→ 理想强,但只配弱中 → 降级中。
        state.bindGoalSpec(.init(objective: "复杂", kind: .task, constraints: ["a", "b", "c"],
                                 successCriteria: ["x", "y"]), to: rid)
        XCTAssertEqual(state.routeBrainTier(taskRecordID: rid), .medium, "复杂→想要强,只配弱中→降级中")
    }
}
