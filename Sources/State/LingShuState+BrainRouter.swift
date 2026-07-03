import Foundation

/// 当前主脑复杂度画像接线。
///
/// 历史上这里承载过"弱/中/强脑端点"配置,但当前产品形态已收敛为**单主脑**:
/// 所有任务、控制面判断和派发执行都只使用当前启用的主脑。
/// `LingShuBrainTier` 只保留为复杂度/脚手架画像,不再选择不同模型端点。
struct LingShuBrainTierConfig: Codable, Sendable, Equatable {
    var provider: String
    var model: String
    var endpoint: String
    var apiKey: String
}

@MainActor
extension LingShuState {

    private static let brainTiersKey = "lingshu.brain.tiers"

    /// 单主脑形态下不读取历史多端点配置,始终返回空。
    func brainTierConfigs() -> [LingShuBrainTier: LingShuBrainTierConfig] {
        [:]
    }

    /// 兼容旧入口:当前不支持多脑端点配置,调用时清理旧配置并保持当前主脑。
    func setBrainTierModel(_ tier: LingShuBrainTier, provider: String, model: String, endpoint: String, apiKey: String) {
        _ = tier; _ = provider; _ = model; _ = endpoint; _ = apiKey
        UserDefaults.standard.removeObject(forKey: Self.brainTiersKey)
        appendTrace(kind: .system, actor: "主脑", title: "单主脑模式", detail: "已忽略多端点配置,继续使用当前启用主脑。")
    }

    /// 当前无多端点可选;所有模型调用均落到当前主脑。
    func availableBrainTiers() -> [LingShuBrainTier] {
        []
    }

    /// 兼容旧调用名:忽略档位,始终返回当前主脑适配器。
    func tierModelAdapter(_ tier: LingShuBrainTier, timeout: TimeInterval? = nil, maxAttempts: Int = 3) -> LingShuGatewayAgentModel {
        _ = tier
        return makeAgentModelAdapter(timeout: timeout, maxAttempts: maxAttempts)
    }

    /// 据任务记录的前置认知抽路由信号。
    func brainRoutingSignals(taskRecordID: String?, escalationCount: Int = 0) -> LingShuBrainRoutingSignals {
        let spec = goalSpec(for: taskRecordID)
        return .init(
            kind: spec?.kind ?? .task,
            constraintCount: spec?.constraints.count ?? 0,
            criteriaCount: spec?.successCriteria.count ?? 0,
            hasBlockingGap: gapAnalysis(for: taskRecordID)?.hasBlockingGap ?? false,
            escalationCount: escalationCount
        )
    }

    /// 复杂度画像:只用于日志/脚手架厚薄判断,不再选择模型端点。
    func routeBrainTier(taskRecordID: String?, escalationCount: Int = 0) -> LingShuBrainTier {
        let signals = brainRoutingSignals(taskRecordID: taskRecordID, escalationCount: escalationCount)
        let desired = LingShuBrainRouter.desiredTier(signals)
        appendTrace(kind: .system, actor: "主脑", title: "复杂度画像", detail: "复杂度=\(desired.rawValue);执行仍由当前主脑处理。")
        return desired
    }

    /// 当前产品形态不支持多脑协同:派发任务也统一使用当前启用主脑。
    /// 保留这个函数名是为了不扩大调用侧改动面。
    func routedModelAdapter(taskRecordID: String?, escalationCount: Int = 0) -> LingShuGatewayAgentModel {
        _ = taskRecordID
        _ = escalationCount
        return makeAgentModelAdapter()
    }
}
