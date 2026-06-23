import Foundation

/// 通用中枢 P5·**强/中/弱脑分层 + 降级**接线(见 [[LingShuBrainRouter]])。
/// 派发任务前据复杂度路由到弱/中/强档脑;某档未配 → 用当前单脑(框架在、配多脑即真分层)。
/// 配置存 UserDefaults:tier → {provider/model/endpoint/apiKey};未配的档落回 `makeAgentModelAdapter`(当前脑)。
struct LingShuBrainTierConfig: Codable, Sendable, Equatable {
    var provider: String
    var model: String
    var endpoint: String
    var apiKey: String
}

@MainActor
extension LingShuState {

    private static let brainTiersKey = "lingshu.brain.tiers"

    /// 已配置的各档脑(tier → 配置)。未配置 → 空(此时所有档落回当前单脑)。
    func brainTierConfigs() -> [LingShuBrainTier: LingShuBrainTierConfig] {
        guard let data = UserDefaults.standard.data(forKey: Self.brainTiersKey),
              let raw = try? JSONDecoder().decode([String: LingShuBrainTierConfig].self, from: data) else { return [:] }
        var out: [LingShuBrainTier: LingShuBrainTierConfig] = [:]
        for (k, v) in raw where !v.endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            if let tier = LingShuBrainTier(rawValue: k) { out[tier] = v }
        }
        return out
    }

    /// 配置某一档脑(持久化;供 UI / MCP 设置多脑)。endpoint 为空视为清除该档。
    func setBrainTierModel(_ tier: LingShuBrainTier, provider: String, model: String, endpoint: String, apiKey: String) {
        var raw = (UserDefaults.standard.data(forKey: Self.brainTiersKey)
            .flatMap { try? JSONDecoder().decode([String: LingShuBrainTierConfig].self, from: $0) }) ?? [:]
        if endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            raw[tier.rawValue] = nil
        } else {
            raw[tier.rawValue] = .init(provider: provider, model: model, endpoint: endpoint, apiKey: apiKey)
        }
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: Self.brainTiersKey) }
        appendTrace(kind: .system, actor: "脑分层", title: endpoint.isEmpty ? "清除\(tier.rawValue)档" : "配置\(tier.rawValue)档",
                    detail: endpoint.isEmpty ? "" : "\(provider)/\(model)")
    }

    /// 已配置(可用)的档位列表(空=未配多脑)。
    func availableBrainTiers() -> [LingShuBrainTier] {
        brainTierConfigs().keys.sorted { $0.rank < $1.rank }
    }

    /// 取某档脑的模型适配器:配了该档 → 用其配置;没配 → 落回当前单脑(makeAgentModelAdapter)。
    func tierModelAdapter(_ tier: LingShuBrainTier, timeout: TimeInterval? = nil, maxAttempts: Int = 3) -> LingShuGatewayAgentModel {
        guard let cfg = brainTierConfigs()[tier] else { return makeAgentModelAdapter(timeout: timeout, maxAttempts: maxAttempts) }
        return LingShuGatewayAgentModel(
            client: remoteModelClient, provider: cfg.provider, model: cfg.model, endpoint: cfg.endpoint,
            protocolName: "OpenAI 兼容", apiKey: cfg.apiKey, temperature: temperature,
            timeout: timeout ?? codexTimeoutSeconds, maxAttempts: maxAttempts
        )
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

    /// 路由档位:复杂度 → 理想档 → 据可用档降级 → 落 trace。返回最终档(供 tierModelAdapter 选脑)。
    func routeBrainTier(taskRecordID: String?, escalationCount: Int = 0) -> LingShuBrainTier {
        let signals = brainRoutingSignals(taskRecordID: taskRecordID, escalationCount: escalationCount)
        let available = availableBrainTiers()
        let desired = LingShuBrainRouter.desiredTier(signals)
        let chosen = LingShuBrainRouter.resolve(desired: desired, available: available)
        let note: String
        if available.isEmpty {
            note = "复杂度→\(desired.rawValue)档;未配多脑,用当前脑。"
        } else if chosen != desired {
            note = "复杂度→\(desired.rawValue)档,该档未配→降级到 \(chosen.rawValue)档。"
        } else {
            note = "复杂度→\(chosen.rawValue)档(已配)。"
        }
        appendTrace(kind: .system, actor: "脑分层", title: "脑路由", detail: note)
        return chosen
    }

    /// 路由并取该档的模型适配器(派发任务用):一步到位。
    func routedModelAdapter(taskRecordID: String?, escalationCount: Int = 0) -> LingShuGatewayAgentModel {
        tierModelAdapter(routeBrainTier(taskRecordID: taskRecordID, escalationCount: escalationCount))
    }
}
