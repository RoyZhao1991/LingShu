import XCTest
@testable import LingShuMac

/// 通用中枢 P6+·模块变体注册表(无界自进化使能件):注册/一键切换/一键回退(纯)+ 运行时热切换执行策略(State)。
final class ModuleVariantTests: XCTestCase {

    // MARK: 纯注册表

    func testRegisterFirstIsActiveBaseline() {
        var reg = LingShuModuleVariantRegistry()
        let base = LingShuModuleVariant(slotID: "s", label: "基线", source: "baseline", payload: "")
        reg.register(base)
        XCTAssertEqual(reg.activeVariant(slotID: "s")?.id, base.id, "首个变体=活跃基线")
    }

    func testSwitchAndRollbackOneClick() {
        var reg = LingShuModuleVariantRegistry()
        let base = LingShuModuleVariant(slotID: "s", label: "基线", source: "baseline", payload: "B")
        let v2 = LingShuModuleVariant(slotID: "s", label: "进化v2", source: "authored", payload: "V2")
        let v3 = LingShuModuleVariant(slotID: "s", label: "进化v3", source: "authored", payload: "V3")
        reg.register(base); reg.register(v2); reg.register(v3)
        XCTAssertEqual(reg.activePayload(slotID: "s"), "B", "默认活跃基线")
        // 一键切到 v2。
        XCTAssertTrue(reg.switchActive(slotID: "s", to: v2.id))
        XCTAssertEqual(reg.activePayload(slotID: "s"), "V2")
        // 再切 v3。
        reg.switchActive(slotID: "s", to: v3.id)
        XCTAssertEqual(reg.activePayload(slotID: "s"), "V3")
        // 一键回退 → v2(上一活跃)。
        XCTAssertEqual(reg.rollback(slotID: "s"), v2.id)
        XCTAssertEqual(reg.activePayload(slotID: "s"), "V2")
        // 再回退 → 基线。
        XCTAssertEqual(reg.rollback(slotID: "s"), base.id)
        XCTAssertEqual(reg.activePayload(slotID: "s"), "B")
    }

    func testRollbackWithNoHistoryGoesBaseline() {
        var reg = LingShuModuleVariantRegistry()
        let base = LingShuModuleVariant(slotID: "s", label: "基线", source: "baseline", payload: "B")
        let v2 = LingShuModuleVariant(slotID: "s", label: "v2", source: "authored", payload: "V2")
        reg.register(base); reg.register(v2, activate: true)   // 直接激活 v2(记历史=base)
        XCTAssertEqual(reg.activePayload(slotID: "s"), "V2")
        XCTAssertEqual(reg.rollback(slotID: "s"), base.id, "回退到基线")
        XCTAssertNil(reg.rollback(slotID: "s") == nil ? "?" : nil)   // 再回退:历史空→仍回基线(不崩)
    }

    func testSwitchToUnknownFails() {
        var reg = LingShuModuleVariantRegistry()
        reg.register(.init(slotID: "s", label: "b", source: "baseline", payload: "B"))
        XCTAssertFalse(reg.switchActive(slotID: "s", to: "nope"))
    }

    // MARK: State 层:持久化 + 运行时热切换执行策略(不重启)

    @MainActor
    func testRuntimeHotSwapExecutionStrategy() {
        let key = "lingshu.module.variants"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        let slot = LingShuModuleSlots.executionGuidance

        // 基线:执行策略空 → 引导不被改。
        state.ensureModuleBaseline(slotID: slot, label: "执行策略·基线", payload: "")
        XCTAssertEqual(state.executionStrategyAddendum(), "", "基线不改行为")

        // 注册一个自进化变体(inactive=先不生效,符合人批后切换原则)。
        let vid = state.registerModuleVariant(slotID: slot, label: "更稳健执行策略", source: "authored",
                                              payload: "【执行策略】先列计划再动手,关键步骤留可回读证据。", activate: false)
        XCTAssertEqual(state.executionStrategyAddendum(), "", "注册但未切换→运行时仍走基线")

        // 一键切换 → 运行时引导立刻变(热切换,不重启)。
        XCTAssertTrue(state.switchModuleVariant(slotID: slot, to: vid))
        XCTAssertTrue(state.executionStrategyAddendum().contains("先列计划再动手"), "切换后运行时执行策略立即生效")
        // 也体现在统一执行引导组装里。
        XCTAssertTrue(state.assembledExecutionGuidance(base: nil, taskRecordID: nil).contains("先列计划再动手"))

        // 一键回退 → 立刻回基线。
        XCTAssertNotNil(state.rollbackModuleVariant(slotID: slot))
        XCTAssertEqual(state.executionStrategyAddendum(), "", "回退后立即回基线,瞬时可逆")
    }
}
