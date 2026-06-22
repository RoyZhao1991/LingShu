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

    func testRemoveProtectsBaselineAndActive() {
        var reg = LingShuModuleVariantRegistry()
        let base = LingShuModuleVariant(slotID: "s", label: "基线", source: "baseline", payload: "B")
        let v2 = LingShuModuleVariant(slotID: "s", label: "v2", source: "authored", payload: "V2")
        let v3 = LingShuModuleVariant(slotID: "s", label: "v3", source: "authored", payload: "V3")
        reg.register(base); reg.register(v2); reg.register(v3, activate: true)   // 活跃=v3
        XCTAssertFalse(reg.remove(slotID: "s", variantID: base.id), "基线不可删")
        XCTAssertFalse(reg.remove(slotID: "s", variantID: v3.id), "活跃不可删")
        XCTAssertTrue(reg.remove(slotID: "s", variantID: v2.id), "非活跃自进化变体可删")
        XCTAssertEqual(reg.variants(slotID: "s").count, 2)
        XCTAssertFalse(reg.remove(slotID: "s", variantID: "nope"), "未知 id 删除失败")
        // 删掉的变体从历史栈清掉:回退仍安全回基线(v3 历史里曾是 base)。
        XCTAssertEqual(reg.rollback(slotID: "s"), base.id)
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

    // MARK: 留账1 — 更多槽位接进注册表(行为人格片段 / 数值参数 / 编译核心组合器)

    @MainActor
    func testPersonaStrategyHotSwap() {
        let key = "lingshu.module.variants"
        UserDefaults.standard.removeObject(forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        state.brainBenchmarkResult = LingShuBrainBenchmarkResult(brainID: "mid", score: 60, passedCount: 6, totalCount: 10, rows: [])   // 钉中档:basline persona=""
        XCTAssertEqual(state.personaStrategyAddendum(), "", "基线人格策略(中档)空=不改系统提示")
        let vid = state.registerModuleVariant(slotID: LingShuModuleSlots.personaStrategy, label: "更克制",
                                              source: "authored", payload: "回答更简洁,先给结论。", activate: false)
        XCTAssertEqual(state.personaStrategyAddendum(), "", "注册未切换→仍空")
        XCTAssertTrue(state.switchModuleVariant(slotID: LingShuModuleSlots.personaStrategy, to: vid))
        XCTAssertTrue(state.personaStrategyAddendum().contains("先给结论"), "切换后人格策略热生效")
        XCTAssertNotNil(state.rollbackModuleVariant(slotID: LingShuModuleSlots.personaStrategy))
        XCTAssertEqual(state.personaStrategyAddendum(), "", "回退立即回基线")
    }

    @MainActor
    func testAcquisitionCeilingNumericParamSlot() {
        let key = "lingshu.module.variants"
        UserDefaults.standard.removeObject(forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        // 基线在用→据当前脑动态调整。钉死中档(脑力测评60→capability≈60=balanced),不受持久化净分影响。
        state.brainBenchmarkResult = LingShuBrainBenchmarkResult(brainID: "mid", score: 60, passedCount: 6, totalCount: 10, rows: [])
        XCTAssertEqual(state.acquisitionCeilingOverride(), 2, "基线→据当前脑(中档)默认2")
        // 合法数值生效(人覆盖优先,盖过脑力档)。
        let v3 = state.registerModuleVariant(slotID: LingShuModuleSlots.acquisitionCeiling, label: "3轮",
                                             source: "manual", payload: "3", activate: true)
        XCTAssertEqual(state.acquisitionCeilingOverride(), 3, "数值参数槽热生效")
        // 越界夹紧。
        let v9 = state.registerModuleVariant(slotID: LingShuModuleSlots.acquisitionCeiling, label: "9轮(越界)",
                                             source: "manual", payload: "9", activate: true)
        XCTAssertEqual(state.acquisitionCeilingOverride(), 5, "越界夹到上限5")
        // 非法 payload → nil(落回代码默认)。
        let vbad = state.registerModuleVariant(slotID: LingShuModuleSlots.acquisitionCeiling, label: "乱填",
                                               source: "manual", payload: "abc", activate: true)
        XCTAssertNil(state.acquisitionCeilingOverride(), "非法数值→nil")
        _ = (v3, v9, vbad)
    }

    @MainActor
    func testCompiledCoreComposerSwitchChangesGuidanceOrder() {
        let key = "lingshu.module.variants"
        UserDefaults.standard.removeObject(forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        state.brainBenchmarkResult = LingShuBrainBenchmarkResult(brainID: "mid", score: 60, passedCount: 6, totalCount: 10, rows: [])   // 钉中档:基线组合器=append
        // 基线=append(中档默认编译实现)。
        XCTAssertEqual(type(of: state.activeGuidanceComposer()).key, "append", "基线组合器(中档)=append")
        // 给执行策略放一个可辨识片段,激活,观察默认 append 把它放在最后。
        let stratVid = state.registerModuleVariant(slotID: LingShuModuleSlots.executionGuidance, label: "策略",
                                                   source: "authored", payload: "STRATEGY_MARKER", activate: true)
        let baseStr = "BASE_EXPERIENCE"
        let appendOut = state.assembledExecutionGuidance(base: baseStr, taskRecordID: nil)
        XCTAssertTrue(appendOut.contains("STRATEGY_MARKER"))
        // 切到编译核心变体 prepend → 策略片段被提到经验之前(同一输入,顺序变了=编译核心变体热切换)。
        let prependVid = state.registerModuleVariant(slotID: LingShuModuleSlots.guidanceAssembly, label: "策略前置",
                                                     source: "authored", payload: "prepend", activate: true)
        XCTAssertEqual(type(of: state.activeGuidanceComposer()).key, "prepend")
        let prependOut = state.assembledExecutionGuidance(base: baseStr, taskRecordID: nil)
        XCTAssertTrue(prependOut.contains("STRATEGY_MARKER"))
        // append:策略在 base 之后;prepend:策略在 base 之前。
        let appendStratIdx = appendOut.range(of: "STRATEGY_MARKER")!.lowerBound
        let appendBaseIdx = appendOut.range(of: "BASE_EXPERIENCE")!.lowerBound
        let prependStratIdx = prependOut.range(of: "STRATEGY_MARKER")!.lowerBound
        let prependBaseIdx = prependOut.range(of: "BASE_EXPERIENCE")!.lowerBound
        XCTAssertTrue(appendStratIdx > appendBaseIdx, "append:策略后置")
        XCTAssertTrue(prependStratIdx < prependBaseIdx, "prepend:策略前置(编译核心变体真切换生效)")
        // 一键回退编译核心变体 → 回 append。
        XCTAssertNotNil(state.rollbackModuleVariant(slotID: LingShuModuleSlots.guidanceAssembly))
        XCTAssertEqual(type(of: state.activeGuidanceComposer()).key, "append", "回退后回默认编译实现")
        _ = (stratVid, prependVid)
    }

    @MainActor
    func testEnsureAllBaselinesCreatesEverySlot() {
        let key = "lingshu.module.variants"
        UserDefaults.standard.removeObject(forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()   // init 即 ensureAllModuleBaselines
        let reg = state.moduleRegistry()
        for slot in LingShuModuleSlots.all {
            XCTAssertNotNil(reg.activeVariant(slotID: slot), "槽位 \(slot) 应有基线")
        }
        XCTAssertEqual(reg.activePayload(slotID: LingShuModuleSlots.guidanceAssembly), "append", "编译核心组合器基线=append")
    }

    // MARK: 据当前脑动态调整 — 脑力档驱动各槽位默认 + 人覆盖优先

    @MainActor
    func testTierDrivenSlotDefaultsAndHumanOverride() {
        let key = "lingshu.module.variants"
        UserDefaults.standard.removeObject(forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        // 强脑(高脑力测评)→ lean档:获取上限放宽3、组合器 append、人格不加。
        state.brainBenchmarkResult = LingShuBrainBenchmarkResult(brainID: "strong", score: 92, passedCount: 9, totalCount: 10, rows: [])
        XCTAssertEqual(state.acquisitionCeilingOverride(), 3, "强脑→放宽获取上限")
        XCTAssertEqual(type(of: state.activeGuidanceComposer()).key, "append", "强脑→默认 append")
        XCTAssertEqual(state.personaStrategyAddendum(), "", "强脑→不加引导人格")
        // 弱脑(低脑力测评)→ guided档:获取上限收紧1、组合器 prepend、人格补引导。
        state.brainBenchmarkResult = LingShuBrainBenchmarkResult(brainID: "weak", score: 28, passedCount: 2, totalCount: 10, rows: [])
        XCTAssertEqual(state.acquisitionCeilingOverride(), 1, "弱脑→收紧获取上限")
        XCTAssertEqual(type(of: state.activeGuidanceComposer()).key, "prepend", "弱脑→策略前置")
        XCTAssertFalse(state.personaStrategyAddendum().isEmpty, "弱脑→补引导人格")
        // 人一键切变体 → **覆盖**脑力档(治理优先):即便弱脑,切到 append 变体就用 append。
        let vid = state.registerModuleVariant(slotID: LingShuModuleSlots.guidanceAssembly, label: "强制append",
                                              source: "manual", payload: "append", activate: true)
        XCTAssertEqual(type(of: state.activeGuidanceComposer()).key, "append", "人切的变体盖过脑力档自动值")
        // 一键回退 → 回到据当前脑(弱脑→prepend)的自动档。
        state.rollbackModuleVariant(slotID: LingShuModuleSlots.guidanceAssembly)
        XCTAssertEqual(type(of: state.activeGuidanceComposer()).key, "prepend", "回退后回据当前脑自动档")
        _ = vid
    }

    // MARK: 留账2 — P6 采纳 → 自动注册成 inactive 执行策略变体

    @MainActor
    func testApprovedImprovementRegistersInactiveVariant() {
        let key = "lingshu.module.variants"
        UserDefaults.standard.removeObject(forKey: key); defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        let before = state.moduleRegistry().variants(slotID: LingShuModuleSlots.executionGuidance).count
        let prop = LingShuImprovementProposal(theme: "把待办同步到第三方服务", occurrences: 3,
                                              suggestion: "补齐对应能力")
        let vid = state.registerImprovementAsVariant(prop)
        let after = state.moduleRegistry()
        let variants = after.variants(slotID: LingShuModuleSlots.executionGuidance)
        XCTAssertEqual(variants.count, before + 1, "采纳后多一条执行策略变体")
        let v = variants.first { $0.id == vid }
        XCTAssertEqual(v?.source, "authored", "来源=自进化")
        XCTAssertNotEqual(after.activeVariant(slotID: LingShuModuleSlots.executionGuidance)?.id, vid,
                          "默认 inactive=不直接生效(符合先不生效、人批切换原则)")
        XCTAssertEqual(state.executionStrategyAddendum(), "", "未切换→运行时仍走基线(空)")
    }
}
