import Foundation

/// 通用中枢 P2 真闭环·**能力获取结果**(纯类型 + 纯分类,可单测)。
///
/// 缺口型任务不再「我没能力」就终止:可自补的缺口要**真去获取**(连 MCP / 自写 author_component / 找技能 / 浏览器 / 工具组合),
/// 补到后还要**最小验证**(新能力真被调通一次)才算可信、可写入 [[LingShuCapabilityGraph]] 复用。
/// 本模块只放**确定性分类**(据执行记录里的工具事件判"补齐到了哪一步"),路径选择交强模型(spec 第11条)。
enum LingShuAcquisitionOutcome: String, Codable, Sendable, Equatable {
    case notAttempted        // 还没尝试获取(自补型缺口应被驱动去补)
    case acquiredVerified    // 已补齐 + 最小验证通过 → 可写图谱、可复用、缺口解除
    case acquiredUnverified  // 补到了但最小验证没过 → 不可信、不写图谱、不算解除
    case failed              // 真尝试了但没补成
    case needsUser           // 必须用户参与(凭据/授权/付费/物理)才能补 → waitingForUser

    var resolvesGap: Bool { self == .acquiredVerified }
}

/// 一次能力获取尝试(typed,随任务记录持久化,供记忆复用 + 验收审计)。
struct LingShuAcquisitionAttempt: Codable, Sendable, Equatable {
    var capability: String   // 缺的能力(missing 或通用动词)
    var path: String         // 走的获取路径:connect_mcp / author_component / discover_skill / browser / compose / local
    var outcome: LingShuAcquisitionOutcome
    var evidence: String
    var at: Date

    init(capability: String, path: String, outcome: LingShuAcquisitionOutcome, evidence: String = "", at: Date = Date()) {
        self.capability = capability
        self.path = path
        self.outcome = outcome
        self.evidence = evidence
        self.at = at
    }
}

/// 据执行记录抽出的获取信号(由 State 层据 record 的工具事件计算,这里只做纯分类)。
struct LingShuAcquisitionSignals: Sendable, Equatable {
    var requiresUser: Bool          // 缺口是需用户类(凭据/授权/付费/物理)
    var attemptedSelfAcquire: Bool  // 调过自补工具(author_component/discover_skill/连MCP/浏览器…)
    var acquireSucceeded: Bool      // 上述自补工具至少一次成功
    var newCapabilityVerified: Bool // 补齐后的新能力**真被调通一次**(最小验证)

    init(requiresUser: Bool, attemptedSelfAcquire: Bool = false, acquireSucceeded: Bool = false, newCapabilityVerified: Bool = false) {
        self.requiresUser = requiresUser
        self.attemptedSelfAcquire = attemptedSelfAcquire
        self.acquireSucceeded = acquireSucceeded
        self.newCapabilityVerified = newCapabilityVerified
    }
}

enum LingShuCapabilityAcquisition {
    /// 纯分类:据信号判定补齐到哪一步。**最小验证未过绝不算 acquiredVerified**(不可信能力不写图谱、不解除缺口)。
    static func classify(_ s: LingShuAcquisitionSignals) -> LingShuAcquisitionOutcome {
        if s.requiresUser { return .needsUser }
        if !s.attemptedSelfAcquire { return .notAttempted }
        if s.acquireSucceeded && s.newCapabilityVerified { return .acquiredVerified }
        if s.acquireSucceeded { return .acquiredUnverified }
        return .failed
    }
}
