import Foundation

/// 通用中枢 P6+·**模块变体注册表**接线(无界自进化使能件,见 [[LingShuModuleVariant]])。
/// 持久化注册表 + **一键切换 / 一键回退**;并接一个**运行时可热切换的具体槽位**「执行策略提示」证明热插拔不重启:
/// 活跃变体的 payload 追加进 `assembledExecutionGuidance`,切换/回退立即影响下一回合,无需重新构建。
/// P6 采纳的改进可注册成 inactive 变体,你一键切生效、一键回退。
enum LingShuModuleSlots {
    /// 运行时可热切换槽位:执行策略提示(追加进统一执行引导)。基线 payload="" = 不改行为。
    static let executionGuidance = "guidance.execution"
    /// 运行时可热切换槽位:**行为人格策略片段**(追加进主会话系统提示尾部,additive,不动身份锚点)。基线 payload="" = 不改行为。
    static let personaStrategy = "guidance.persona"
    /// **数值参数**型槽位:能力获取驱动的安全天花板(payload=整数字符串,如 "3")。基线 payload="" = 用代码默认值。
    static let acquisitionCeiling = "gate.acquisitionCeiling"
    /// **编译核心变体**槽位:执行引导组合器实现键(payload=append/prepend,见 [[LingShuGuidanceComposer]])。基线 payload=append。
    static let guidanceAssembly = "core.guidanceAssembly"

    /// 全部已知槽位(供 UI 列举 + 启动时确保各自有基线)。
    static let all = [executionGuidance, personaStrategy, acquisitionCeiling, guidanceAssembly]

    /// 槽位人读名(UI 显示)。
    static func label(_ slotID: String) -> String {
        switch slotID {
        case executionGuidance: return "执行策略片段(运行时热切换)"
        case personaStrategy:   return "行为人格策略(系统提示尾·热切换)"
        case acquisitionCeiling: return "能力获取驱动上限(数值参数)"
        case guidanceAssembly:  return "执行引导组合器(编译核心变体)"
        default: return slotID
        }
    }
}

@MainActor
extension LingShuState {

    private static let moduleVariantsKey = "lingshu.module.variants"

    func moduleRegistry() -> LingShuModuleVariantRegistry {
        guard let data = UserDefaults.standard.data(forKey: Self.moduleVariantsKey),
              let reg = try? JSONDecoder().decode(LingShuModuleVariantRegistry.self, from: data) else {
            return LingShuModuleVariantRegistry()
        }
        return reg
    }

    private func persistModuleRegistry(_ reg: LingShuModuleVariantRegistry) {
        if let data = try? JSONEncoder().encode(reg) { UserDefaults.standard.set(data, forKey: Self.moduleVariantsKey) }
    }

    /// 确保某槽位有基线变体(payload 多为""=不改行为),否则回退无处可去。返回基线变体 id。
    @discardableResult
    func ensureModuleBaseline(slotID: String, label: String, payload: String = "") -> String {
        var reg = moduleRegistry()
        if let base = reg.variants(slotID: slotID).first(where: { $0.source == "baseline" }) { return base.id }
        let base = LingShuModuleVariant(slotID: slotID, label: label, source: "baseline", payload: payload)
        reg.register(base)
        persistModuleRegistry(reg)
        return base.id
    }

    /// 注册一个新变体(默认 inactive=只入库不切活跃,符合"自进化产物先不生效、人批切换"原则)。返回变体 id。
    @discardableResult
    func registerModuleVariant(slotID: String, label: String, source: String, payload: String, activate: Bool = false) -> String {
        var reg = moduleRegistry()
        let v = LingShuModuleVariant(slotID: slotID, label: label, source: source, payload: payload)
        reg.register(v, activate: activate)
        persistModuleRegistry(reg)
        moduleVariantsRevision += 1
        appendTrace(kind: .system, actor: "模块变体", title: activate ? "注册并切换" : "注册(待切换)",
                    detail: "\(slotID) ← \(label)")
        return v.id
    }

    /// **一键切换**活跃变体(供 UI/MCP 调)。
    @discardableResult
    func switchModuleVariant(slotID: String, to variantID: String) -> Bool {
        var reg = moduleRegistry()
        let ok = reg.switchActive(slotID: slotID, to: variantID)
        if ok { persistModuleRegistry(reg); moduleVariantsRevision += 1; appendTrace(kind: .result, actor: "模块变体", title: "一键切换", detail: "\(slotID) → \(variantID)") }
        return ok
    }

    /// **一键回退**到上一活跃变体/基线(供 UI/MCP 调)。
    @discardableResult
    func rollbackModuleVariant(slotID: String) -> String? {
        var reg = moduleRegistry()
        let target = reg.rollback(slotID: slotID)
        if let target { persistModuleRegistry(reg); moduleVariantsRevision += 1; appendTrace(kind: .warning, actor: "模块变体", title: "一键回退", detail: "\(slotID) ↩ \(target)") }
        return target
    }

    /// **删除变体**(治理:清掉否决/测试变体;基线与活跃不可删——先切走/回退再删)。供 UI/MCP 调。
    @discardableResult
    func removeModuleVariant(slotID: String, variantID: String) -> Bool {
        var reg = moduleRegistry()
        let ok = reg.remove(slotID: slotID, variantID: variantID)
        if ok { persistModuleRegistry(reg); moduleVariantsRevision += 1; appendTrace(kind: .warning, actor: "模块变体", title: "删除变体", detail: "\(slotID) ✕ \(variantID)") }
        return ok
    }

    /// 取槽位活跃变体 payload(运行时取实现)。
    func activeModulePayload(slotID: String) -> String? { moduleRegistry().activePayload(slotID: slotID) }

    /// 启动时确保所有已知槽位都有基线变体(回退有处可去、UI 一上来就列得全)。各基线 payload 默认""=不改行为;
    /// 编译核心组合器基线 payload=append(默认实现键)。幂等。
    func ensureAllModuleBaselines() {
        for slot in LingShuModuleSlots.all {
            let base = (slot == LingShuModuleSlots.guidanceAssembly) ? LingShuAppendStrategyComposer.key : ""
            ensureModuleBaseline(slotID: slot, label: "\(LingShuModuleSlots.label(slot))·基线", payload: base)
        }
    }

    // MARK: - 运行时槽位消费(据当前脑动态调整 + 人/采纳覆盖优先)

    /// **槽位有效 payload**(统一入口):人已一键切到**非基线**变体(或 P6 采纳的策略被切上)→ **用那个**
    /// (人/采纳覆盖优先,不被脑力档盖掉);否则(基线在用、无人覆盖)→ **据当前脑力档自动给默认**——
    /// 这把 P5「据当前脑动态调整」接进 P6+ 变体槽:弱脑自动更引导,强脑自动放权,而任一槽人仍可一键覆盖/回退。
    func effectiveSlotPayload(slotID: String) -> String {
        if let active = moduleRegistry().activeVariant(slotID: slotID), active.source != "baseline" {
            return active.payload.trimmingCharacters(in: .whitespacesAndNewlines)   // 覆盖优先(治理不变)
        }
        return tierDefaultPayload(slotID: slotID)   // 基线在用 → 据当前脑动态调整
    }

    /// 当前脑力档(`currentHarnessTier()` 据脑力测评+运行净分算 lean/balanced/guided)→ 各槽位**自动默认** payload。
    /// 安全:这只填**基线在用时**的默认,人一键切的变体永远盖过它(见 effectiveSlotPayload)。
    func tierDefaultPayload(slotID: String) -> String {
        let tier = currentHarnessTier()
        switch slotID {
        case LingShuModuleSlots.executionGuidance:
            return ""   // 脚手架厚薄已由 harnessKnobPrefix 据档调,执行策略槽默认不重复加;留给人/采纳覆盖
        case LingShuModuleSlots.personaStrategy:
            // 弱脑补一句"先想清楚再动手"的行为引导;中/强脑不加(避免与 harnessKnobPrefix 重复)。
            return tier == .guided ? "遇到不确定先一步步想清楚再动手,复杂处宁可多核对一次,别盲目重试。" : ""
        case LingShuModuleSlots.acquisitionCeiling:
            // 强脑能把多轮获取真用上→放宽;弱脑会 flailing→收紧,早点诚实交还不空耗。
            switch tier { case .lean: return "3"; case .balanced: return "2"; case .guided: return "1" }
        case LingShuModuleSlots.guidanceAssembly:
            // 弱脑更重视开头指令→策略前置(prepend);中/强脑用默认 append。
            return tier == .guided ? LingShuPrependStrategyComposer.key : LingShuAppendStrategyComposer.key
        default:
            return ""
        }
    }

    /// 「执行策略」有效 payload(追加进统一执行引导)。
    func executionStrategyAddendum() -> String { effectiveSlotPayload(slotID: LingShuModuleSlots.executionGuidance) }

    /// 「行为人格策略」有效 payload(追加进主会话系统提示尾;additive 不动身份锚点)。
    func personaStrategyAddendum() -> String { effectiveSlotPayload(slotID: LingShuModuleSlots.personaStrategy) }

    /// 「能力获取驱动上限」有效 payload 解析成整数;非法 → nil(落回代码默认 2)。夹在 [1, 5]。
    func acquisitionCeilingOverride() -> Int? {
        guard let n = Int(effectiveSlotPayload(slotID: LingShuModuleSlots.acquisitionCeiling)) else { return nil }
        return min(5, max(1, n))
    }

    /// 「执行引导组合器」有效 payload → 已编译核心实现(编译核心变体特性开关)。
    func activeGuidanceComposer() -> LingShuGuidanceComposing {
        LingShuGuidanceComposers.resolve(effectiveSlotPayload(slotID: LingShuModuleSlots.guidanceAssembly))
    }
}
