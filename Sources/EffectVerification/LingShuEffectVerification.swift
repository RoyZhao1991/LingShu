import Foundation

/// EffectVerification verifies whether the outside world actually changed as requested.
/// It is separate from the existing P3 acceptance implementation so it can later become the
/// common verifier plugin surface for files, commands, UI, devices and human confirmation.
enum LingShuEffectKind: String, Codable, Sendable, Equatable, CaseIterable {
    case file
    case command
    case ui
    case device
    case environment
    case userConfirmation
    case content
    case unknown
}

enum LingShuEffectVerificationStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case verified
    case failed
    case inconclusive
    case needsUserConfirmation
}

struct LingShuEffectRequirement: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: LingShuEffectKind
    var description: String
    var probe: String?
    var requiredEvidence: [String]

    init(
        id: String = UUID().uuidString,
        kind: LingShuEffectKind,
        description: String,
        probe: String? = nil,
        requiredEvidence: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.description = description
        self.probe = probe
        self.requiredEvidence = requiredEvidence
    }
}

struct LingShuEffectEvidence: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var requirementID: String?
    var source: String
    var summary: String
    var payload: [String: String]
    var confidence: Double
    var capturedAt: Date

    init(
        id: String = UUID().uuidString,
        requirementID: String? = nil,
        source: String,
        summary: String,
        payload: [String: String] = [:],
        confidence: Double = 1,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.requirementID = requirementID
        self.source = source
        self.summary = summary
        self.payload = payload
        self.confidence = max(0, min(1, confidence))
        self.capturedAt = capturedAt
    }
}

struct LingShuEffectVerdict: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var requirementID: String
    var kind: LingShuEffectKind
    var status: LingShuEffectVerificationStatus
    var evidence: [LingShuEffectEvidence]
    var reason: String

    init(
        id: String = UUID().uuidString,
        requirementID: String,
        kind: LingShuEffectKind,
        status: LingShuEffectVerificationStatus,
        evidence: [LingShuEffectEvidence] = [],
        reason: String
    ) {
        self.id = id
        self.requirementID = requirementID
        self.kind = kind
        self.status = status
        self.evidence = evidence
        self.reason = reason
    }
}

struct LingShuEffectVerificationReport: Codable, Sendable, Equatable {
    var verdicts: [LingShuEffectVerdict]
    var createdAt: Date

    init(verdicts: [LingShuEffectVerdict], createdAt: Date = Date()) {
        self.verdicts = verdicts
        self.createdAt = createdAt
    }

    var hasFailure: Bool {
        verdicts.contains { $0.status == .failed }
    }

    var needsHuman: Bool {
        verdicts.contains { $0.status == .needsUserConfirmation }
    }

    var isFullyVerified: Bool {
        !verdicts.isEmpty && verdicts.allSatisfy { $0.status == .verified }
    }

    var summary: String {
        guard !verdicts.isEmpty else { return "真实效果验收:暂无验收项。" }
        return verdicts.map { verdict in
            let mark: String
            switch verdict.status {
            case .verified: mark = "verified"
            case .failed: mark = "failed"
            case .inconclusive: mark = "inconclusive"
            case .needsUserConfirmation: mark = "needs_user_confirmation"
            }
            return "[\(mark)] \(verdict.reason)"
        }.joined(separator: "\n")
    }

    static func make(requirements: [LingShuEffectRequirement], evidence: [LingShuEffectEvidence]) -> LingShuEffectVerificationReport {
        let verdicts = requirements.map { requirement -> LingShuEffectVerdict in
            let related = evidence.filter { $0.requirementID == requirement.id }
            if related.contains(where: { $0.payload["status"] == "failed" }) {
                return LingShuEffectVerdict(
                    requirementID: requirement.id,
                    kind: requirement.kind,
                    status: .failed,
                    evidence: related,
                    reason: "\(requirement.description) 未通过外部证据核验"
                )
            }
            if !related.isEmpty && related.contains(where: { $0.confidence >= 0.8 }) {
                return LingShuEffectVerdict(
                    requirementID: requirement.id,
                    kind: requirement.kind,
                    status: .verified,
                    evidence: related,
                    reason: "\(requirement.description) 已由证据确认"
                )
            }
            if requirement.kind == .userConfirmation {
                return LingShuEffectVerdict(
                    requirementID: requirement.id,
                    kind: requirement.kind,
                    status: .needsUserConfirmation,
                    evidence: related,
                    reason: "\(requirement.description) 需要用户确认"
                )
            }
            return LingShuEffectVerdict(
                requirementID: requirement.id,
                kind: requirement.kind,
                status: .inconclusive,
                evidence: related,
                reason: "\(requirement.description) 暂无足够证据"
            )
        }
        return LingShuEffectVerificationReport(verdicts: verdicts)
    }
}

protocol LingShuEffectVerifier: Sendable {
    var kind: LingShuEffectKind { get }
    func verify(_ requirement: LingShuEffectRequirement, evidence: [LingShuEffectEvidence]) async -> LingShuEffectVerdict
}
