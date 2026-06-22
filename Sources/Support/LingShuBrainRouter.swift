import Foundation

/// 通用中枢 P5·**强/中/弱脑分层 + 降级**(纯类型 + 路由决策,可单测)。
///
/// 按任务复杂度把活路由到合适档位的脑(弱/中/强),并在理想档不可用时**降级**到可用档(配了多脑才有真分层;
/// 单脑时路由照算但都落到当前脑=框架在、分层空)。对应 15 条要求 #9。
/// 路由信号从 GoalSpec(kind/约束数/成功标准数)+ 缺口(是否有阻断)+ 升级计数 推导;决策纯函数。
enum LingShuBrainTier: String, Codable, Sendable, Equatable, CaseIterable {
    case weak, medium, strong

    /// 由弱到强的序(升级/降级用)。
    var rank: Int { switch self { case .weak: return 0; case .medium: return 1; case .strong: return 2 } }
}

struct LingShuBrainRoutingSignals: Sendable, Equatable {
    var kind: LingShuGoalKind        // task/question/chat/interaction/unknown
    var constraintCount: Int
    var criteriaCount: Int
    var hasBlockingGap: Bool         // 有阻断缺口=要补齐/编排,更难
    var escalationCount: Int         // 在更低档失败重试过几次 → 升档(0=首次)

    init(kind: LingShuGoalKind = .task, constraintCount: Int = 0, criteriaCount: Int = 0,
         hasBlockingGap: Bool = false, escalationCount: Int = 0) {
        self.kind = kind
        self.constraintCount = constraintCount
        self.criteriaCount = criteriaCount
        self.hasBlockingGap = hasBlockingGap
        self.escalationCount = escalationCount
    }
}

enum LingShuBrainRouter {
    /// 据复杂度信号定**理想档位**(纯函数,零领域)。复杂度打分 → 弱/中/强;每次升级大幅抬档。
    static func desiredTier(_ s: LingShuBrainRoutingSignals) -> LingShuBrainTier {
        var score = 0
        switch s.kind {
        case .task: score += 2
        case .interaction: score += 1
        case .question, .unknown: score += 0
        }
        score += min(max(s.constraintCount, 0), 3)
        score += min(max(s.criteriaCount, 0), 3)
        if s.hasBlockingGap { score += 2 }
        score += max(s.escalationCount, 0) * 3   // 低档失败→升档
        if score >= 6 { return .strong }
        if score >= 2 { return .medium }
        return .weak
    }

    /// 理想档→**可用档**:取可用里 ≤ 理想 的最高档(理想档没配就降级到更低的可用档);
    /// 若没有 ≤ 理想 的(只配了更强的),退而用可用里最低档。available 为空 → 返回理想档(由上层落到当前单脑)。
    static func resolve(desired: LingShuBrainTier, available: [LingShuBrainTier]) -> LingShuBrainTier {
        guard !available.isEmpty else { return desired }
        let atOrBelow = available.filter { $0.rank <= desired.rank }
        if let best = atOrBelow.max(by: { $0.rank < $1.rank }) { return best }
        return available.min(by: { $0.rank < $1.rank }) ?? desired
    }

    /// 一步到位:据信号 + 可用档,给出最终档位。
    static func route(_ s: LingShuBrainRoutingSignals, available: [LingShuBrainTier]) -> LingShuBrainTier {
        resolve(desired: desiredTier(s), available: available)
    }
}
