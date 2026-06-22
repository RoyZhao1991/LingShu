import Foundation

/// 通用中枢 P6+·**模块变体注册表**(无界自进化的安全使能件)(纯类型 + 切换/回退逻辑,可单测)。
///
/// 安全模型从「禁止改核心」换成「**任何改动都是模块化、可一键切换、可一键回退**」:每个**可进化槽位**(slot)
/// 存多版本**变体**(基线 + 自进化版)+ 活跃指针 + 切换历史栈 → **一键切活跃变体 / 一键回退上一版**。
/// 运行时可插拔层(提示策略/技能/工具脚本/连接器)真热切换不重启;编译核心变体则 payload=开关键、改动过一次构建后同样可切换/回退。
/// 这让"连核心也能自进化"安全成立:出问题瞬时可逆。
struct LingShuModuleVariant: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var slotID: String     // 进化槽位(如 guidance.execution / tool.notion-sync / skill.ppt / core.someGate)
    var label: String      // 人读名
    var source: String     // baseline / authored / discovered / manual
    var payload: String    // 变体载体:可插拔层=脚本/提示/配置;编译核心=特性开关键
    var createdAt: Date

    init(id: String = "var-\(UUID().uuidString.prefix(8))", slotID: String, label: String,
         source: String, payload: String, createdAt: Date = Date()) {
        self.id = id; self.slotID = slotID; self.label = label
        self.source = source; self.payload = payload; self.createdAt = createdAt
    }
}

struct LingShuModuleSlot: Codable, Sendable, Equatable {
    var slotID: String
    var variants: [LingShuModuleVariant]
    var activeVariantID: String
    var history: [String]    // 历史活跃栈(供一键回退)
}

struct LingShuModuleVariantRegistry: Codable, Sendable, Equatable {
    var slots: [String: LingShuModuleSlot] = [:]

    /// 注册一个变体。首个变体自动成为活跃基线;`activate=true` 则切为活跃(记历史)。已存在(同 id)幂等。
    mutating func register(_ v: LingShuModuleVariant, activate: Bool = false) {
        var slot = slots[v.slotID] ?? LingShuModuleSlot(slotID: v.slotID, variants: [], activeVariantID: v.id, history: [])
        if !slot.variants.contains(where: { $0.id == v.id }) { slot.variants.append(v) }
        if slot.variants.count == 1 { slot.activeVariantID = v.id }            // 首个=活跃基线
        if activate && slot.activeVariantID != v.id {
            slot.history.append(slot.activeVariantID)
            slot.activeVariantID = v.id
        }
        slots[v.slotID] = slot
    }

    /// **一键切换**活跃变体(记当前到历史栈)。变体不存在 → false。
    @discardableResult
    mutating func switchActive(slotID: String, to variantID: String) -> Bool {
        guard var slot = slots[slotID], slot.variants.contains(where: { $0.id == variantID }) else { return false }
        guard slot.activeVariantID != variantID else { return true }
        slot.history.append(slot.activeVariantID)
        slot.activeVariantID = variantID
        slots[slotID] = slot
        return true
    }

    /// **一键回退**:切回历史上一个活跃变体;无历史则回到基线(source==baseline 或首个变体)。返回回退到的变体 id。
    @discardableResult
    mutating func rollback(slotID: String) -> String? {
        guard var slot = slots[slotID] else { return nil }
        let target: String
        if let prev = slot.history.popLast() {
            target = prev
        } else if let baseline = slot.variants.first(where: { $0.source == "baseline" }) ?? slot.variants.first {
            target = baseline.id
        } else { return nil }
        slot.activeVariantID = target
        slots[slotID] = slot
        return target
    }

    /// 删除一个变体(治理:清掉被否决/测试用的变体)。**基线不可删、当前活跃不可删**(先切走/回退再删)。成功→true。
    @discardableResult
    mutating func remove(slotID: String, variantID: String) -> Bool {
        guard var slot = slots[slotID],
              let v = slot.variants.first(where: { $0.id == variantID }),
              v.source != "baseline", slot.activeVariantID != variantID else { return false }
        slot.variants.removeAll { $0.id == variantID }
        slot.history.removeAll { $0 == variantID }   // 历史栈里同步清掉,回退不会指向已删变体
        slots[slotID] = slot
        return true
    }

    func activeVariant(slotID: String) -> LingShuModuleVariant? {
        guard let slot = slots[slotID] else { return nil }
        return slot.variants.first { $0.id == slot.activeVariantID }
    }

    /// 取槽位活跃变体的 payload(运行时据此取实现);无槽/无活跃 → nil。
    func activePayload(slotID: String) -> String? { activeVariant(slotID: slotID)?.payload }

    func variants(slotID: String) -> [LingShuModuleVariant] { slots[slotID]?.variants ?? [] }
}
