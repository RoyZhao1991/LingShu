import Foundation

/// 通用中枢 P6+·**模块变体注册表**接线(无界自进化使能件,见 [[LingShuModuleVariant]])。
/// 持久化注册表 + **一键切换 / 一键回退**;并接一个**运行时可热切换的具体槽位**「执行策略提示」证明热插拔不重启:
/// 活跃变体的 payload 追加进 `assembledExecutionGuidance`,切换/回退立即影响下一回合,无需重新构建。
/// P6 采纳的改进可注册成 inactive 变体,你一键切生效、一键回退。
enum LingShuModuleSlots {
    /// 运行时可热切换槽位:执行策略提示(追加进统一执行引导)。基线 payload="" = 不改行为。
    static let executionGuidance = "guidance.execution"
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
        appendTrace(kind: .system, actor: "模块变体", title: activate ? "注册并切换" : "注册(待切换)",
                    detail: "\(slotID) ← \(label)")
        return v.id
    }

    /// **一键切换**活跃变体(供 UI/MCP 调)。
    @discardableResult
    func switchModuleVariant(slotID: String, to variantID: String) -> Bool {
        var reg = moduleRegistry()
        let ok = reg.switchActive(slotID: slotID, to: variantID)
        if ok { persistModuleRegistry(reg); appendTrace(kind: .result, actor: "模块变体", title: "一键切换", detail: "\(slotID) → \(variantID)") }
        return ok
    }

    /// **一键回退**到上一活跃变体/基线(供 UI/MCP 调)。
    @discardableResult
    func rollbackModuleVariant(slotID: String) -> String? {
        var reg = moduleRegistry()
        let target = reg.rollback(slotID: slotID)
        if let target { persistModuleRegistry(reg); appendTrace(kind: .warning, actor: "模块变体", title: "一键回退", detail: "\(slotID) ↩ \(target)") }
        return target
    }

    /// 取槽位活跃变体 payload(运行时取实现)。
    func activeModulePayload(slotID: String) -> String? { moduleRegistry().activePayload(slotID: slotID) }

    /// 运行时槽位消费:把「执行策略」活跃变体的 payload 追加进执行引导(空/无 → 不改)。证明热切换不重启。
    func executionStrategyAddendum() -> String {
        let payload = (activeModulePayload(slotID: LingShuModuleSlots.executionGuidance) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload
    }
}
