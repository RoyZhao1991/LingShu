import Foundation

/// AdaptiveBrain chooses a brain by required capability, not by a hard-coded model name.
enum LingShuBrainCapability: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case fastChat
    case deepReasoning
    case codeExecution
    case toolCalling
    case visionReasoning
    case audioRealtime
    case longContext
    case lowCost
    case highReliability
    case localPrivate
}

enum LingShuBrainRiskLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high
    case critical
}

struct LingShuBrainProfile: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var capabilities: Set<LingShuBrainCapability>
    var maxContextTokens: Int
    var latencyScore: Double
    var reliabilityScore: Double
    var costScore: Double
    var available: Bool

    init(
        id: String,
        displayName: String,
        capabilities: Set<LingShuBrainCapability>,
        maxContextTokens: Int = 0,
        latencyScore: Double = 0.5,
        reliabilityScore: Double = 0.5,
        costScore: Double = 0.5,
        available: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.maxContextTokens = maxContextTokens
        self.latencyScore = max(0, min(1, latencyScore))
        self.reliabilityScore = max(0, min(1, reliabilityScore))
        self.costScore = max(0, min(1, costScore))
        self.available = available
    }
}

struct LingShuBrainTaskDemand: Codable, Sendable, Equatable {
    var requiredCapabilities: Set<LingShuBrainCapability>
    var preferredCapabilities: Set<LingShuBrainCapability>
    var risk: LingShuBrainRiskLevel
    var contextTokens: Int
    var latencySensitive: Bool
    var privacySensitive: Bool

    init(
        requiredCapabilities: Set<LingShuBrainCapability> = [],
        preferredCapabilities: Set<LingShuBrainCapability> = [],
        risk: LingShuBrainRiskLevel = .medium,
        contextTokens: Int = 0,
        latencySensitive: Bool = false,
        privacySensitive: Bool = false
    ) {
        self.requiredCapabilities = requiredCapabilities
        self.preferredCapabilities = preferredCapabilities
        self.risk = risk
        self.contextTokens = max(0, contextTokens)
        self.latencySensitive = latencySensitive
        self.privacySensitive = privacySensitive
    }
}

struct LingShuBrainRoutingDecision: Codable, Sendable, Equatable {
    var selectedBrainID: String?
    var alternativeBrainIDs: [String]
    var missingCapabilities: Set<LingShuBrainCapability>
    var reason: String

    var canRun: Bool { selectedBrainID != nil && missingCapabilities.isEmpty }
}

enum LingShuAdaptiveBrainRouter {
    static func route(
        demand: LingShuBrainTaskDemand,
        profiles: [LingShuBrainProfile]
    ) -> LingShuBrainRoutingDecision {
        let available = profiles.filter { $0.available }
        guard !available.isEmpty else {
            return LingShuBrainRoutingDecision(
                selectedBrainID: nil,
                alternativeBrainIDs: [],
                missingCapabilities: demand.requiredCapabilities,
                reason: "没有可用模型"
            )
        }

        let eligible = available.filter { profile in
            demand.requiredCapabilities.isSubset(of: profile.capabilities)
                && profile.maxContextTokens >= demand.contextTokens
                && (!demand.privacySensitive || profile.capabilities.contains(.localPrivate))
        }

        guard !eligible.isEmpty else {
            let covered = available.reduce(into: Set<LingShuBrainCapability>()) { acc, profile in
                acc.formUnion(profile.capabilities)
            }
            let missing = demand.requiredCapabilities.subtracting(covered)
            return LingShuBrainRoutingDecision(
                selectedBrainID: nil,
                alternativeBrainIDs: available.map(\.id).sorted(),
                missingCapabilities: missing.isEmpty ? demand.requiredCapabilities : missing,
                reason: "当前模型池无法满足任务能力需求"
            )
        }

        let ranked = eligible.sorted { a, b in
            score(a, demand: demand) > score(b, demand: demand)
        }
        let selected = ranked[0]
        return LingShuBrainRoutingDecision(
            selectedBrainID: selected.id,
            alternativeBrainIDs: ranked.dropFirst().map(\.id),
            missingCapabilities: [],
            reason: "按能力画像选择 \(selected.displayName)"
        )
    }

    private static func score(_ profile: LingShuBrainProfile, demand: LingShuBrainTaskDemand) -> Double {
        var value = 0.0
        value += Double(profile.capabilities.intersection(demand.preferredCapabilities).count) * 1.5
        value += profile.reliabilityScore * reliabilityWeight(for: demand.risk)
        value += demand.latencySensitive ? profile.latencyScore * 2.0 : profile.latencyScore * 0.4
        value += profile.costScore * (demand.risk == .low ? 1.2 : 0.2)
        value += Double(max(0, profile.maxContextTokens - demand.contextTokens)) / 1_000_000.0
        return value
    }

    private static func reliabilityWeight(for risk: LingShuBrainRiskLevel) -> Double {
        switch risk {
        case .low: return 0.8
        case .medium: return 1.5
        case .high: return 2.5
        case .critical: return 4.0
        }
    }
}
