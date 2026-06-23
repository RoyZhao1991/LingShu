import Foundation

/// SafeSelfEvolution defines the safety rails for LingShu improving itself.
/// The first version only models proposals and gates; it does not mutate code or wire into runtime.
enum LingShuEvolutionLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case memoryLesson
    case generatedTool
    case adapter
    case peripheralModule
    case coreModule
}

enum LingShuEvolutionRisk: String, Codable, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high
    case critical
}

enum LingShuEvolutionProposalStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case draft
    case pendingApproval
    case approved
    case running
    case validated
    case failed
    case rejected
    case rolledBack
}

struct LingShuEvolutionTrigger: Codable, Sendable, Equatable {
    var source: String
    var symptom: String
    var repeatedCount: Int
    var relatedTaskIDs: [String]

    init(source: String, symptom: String, repeatedCount: Int = 1, relatedTaskIDs: [String] = []) {
        self.source = source
        self.symptom = symptom
        self.repeatedCount = max(1, repeatedCount)
        self.relatedTaskIDs = relatedTaskIDs
    }
}

struct LingShuEvolutionProposal: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var level: LingShuEvolutionLevel
    var risk: LingShuEvolutionRisk
    var objective: String
    var rationale: String
    var trigger: LingShuEvolutionTrigger
    var touchedAreas: [String]
    var validationPlan: [String]
    var rollbackPlan: String
    var status: LingShuEvolutionProposalStatus
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        level: LingShuEvolutionLevel,
        risk: LingShuEvolutionRisk,
        objective: String,
        rationale: String,
        trigger: LingShuEvolutionTrigger,
        touchedAreas: [String] = [],
        validationPlan: [String] = [],
        rollbackPlan: String = "",
        status: LingShuEvolutionProposalStatus = .draft,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.level = level
        self.risk = risk
        self.objective = objective
        self.rationale = rationale
        self.trigger = trigger
        self.touchedAreas = touchedAreas
        self.validationPlan = validationPlan
        self.rollbackPlan = rollbackPlan
        self.status = status
        self.createdAt = createdAt
    }
}

struct LingShuEvolutionGateDecision: Codable, Sendable, Equatable {
    var allowedToRun: Bool
    var requiresHumanApproval: Bool
    var requiredApprovals: [String]
    var reason: String
}

enum LingShuSafeSelfEvolutionPolicy {
    static func evaluate(_ proposal: LingShuEvolutionProposal) -> LingShuEvolutionGateDecision {
        var approvals: [String] = []
        if proposal.risk == .high || proposal.risk == .critical {
            approvals.append("human_owner")
        }
        if proposal.level == .coreModule {
            approvals.append(contentsOf: ["human_owner", "regression_gate", "rollback_plan"])
        }
        if proposal.level == .peripheralModule && proposal.validationPlan.isEmpty {
            approvals.append("validation_plan")
        }
        if proposal.rollbackPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [.adapter, .peripheralModule, .coreModule].contains(proposal.level) {
            approvals.append("rollback_plan")
        }

        let unique = Array(Set(approvals)).sorted()
        if unique.isEmpty {
            return LingShuEvolutionGateDecision(
                allowedToRun: true,
                requiresHumanApproval: false,
                requiredApprovals: [],
                reason: "低风险改进可进入沙箱验证"
            )
        }
        return LingShuEvolutionGateDecision(
            allowedToRun: false,
            requiresHumanApproval: unique.contains("human_owner"),
            requiredApprovals: unique,
            reason: "该自进化提案需要先补齐审批或安全材料"
        )
    }

    static func normalizedRisk(level: LingShuEvolutionLevel, requestedRisk: LingShuEvolutionRisk) -> LingShuEvolutionRisk {
        switch level {
        case .memoryLesson:
            return requestedRisk == .critical ? .medium : requestedRisk
        case .generatedTool:
            return requestedRisk
        case .adapter:
            return maxRisk(requestedRisk, .medium)
        case .peripheralModule:
            return maxRisk(requestedRisk, .high)
        case .coreModule:
            return .critical
        }
    }

    private static func maxRisk(_ a: LingShuEvolutionRisk, _ b: LingShuEvolutionRisk) -> LingShuEvolutionRisk {
        riskRank(a) >= riskRank(b) ? a : b
    }

    private static func riskRank(_ risk: LingShuEvolutionRisk) -> Int {
        switch risk {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}
