import Foundation

/// CapabilityProbe is the discovery side of the capability system. It does not replace the
/// existing CapabilityGraph; LingShuState translates observations into graph entries and task memory.
enum LingShuProbeTargetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case software
    case service
    case device
    case model
    case dataSource
    case networkEndpoint
    case unknown
}

enum LingShuCapabilityProbeStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case available
    case probable
    case requiresAuth
    case requiresDriver
    case unavailable
    case unsafe
    case unknown

    var isUsableWithoutIntervention: Bool {
        self == .available || self == .probable
    }
}

struct LingShuProbeTarget: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: LingShuProbeTargetKind
    var name: String
    var locator: String?
    var metadata: [String: String]

    init(
        id: String,
        kind: LingShuProbeTargetKind,
        name: String,
        locator: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.locator = locator
        self.metadata = metadata
    }
}

struct LingShuCapabilityProbeObservation: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var targetID: String
    var capabilityID: String
    var verb: String
    var description: String
    var status: LingShuCapabilityProbeStatus
    var confidence: Double
    var evidence: [String]
    var observedAt: Date

    init(
        id: String = UUID().uuidString,
        targetID: String,
        capabilityID: String,
        verb: String,
        description: String,
        status: LingShuCapabilityProbeStatus,
        confidence: Double,
        evidence: [String] = [],
        observedAt: Date = Date()
    ) {
        self.id = id
        self.targetID = targetID
        self.capabilityID = capabilityID
        self.verb = verb
        self.description = description
        self.status = status
        self.confidence = max(0, min(1, confidence))
        self.evidence = evidence
        self.observedAt = observedAt
    }
}

protocol LingShuCapabilityProbe: Sendable {
    var id: String { get }
    var supportedTargetKinds: Set<LingShuProbeTargetKind> { get }
    func probe(_ target: LingShuProbeTarget) async -> [LingShuCapabilityProbeObservation]
}

actor LingShuCapabilityProbeRegistry {
    private var probes: [String: any LingShuCapabilityProbe] = [:]

    func register(_ probe: any LingShuCapabilityProbe) {
        probes[probe.id] = probe
    }

    func unregister(id: String) {
        probes.removeValue(forKey: id)
    }

    func registeredProbeIDs() -> [String] {
        probes.keys.sorted()
    }

    func probe(_ target: LingShuProbeTarget) async -> [LingShuCapabilityProbeObservation] {
        let runners = probes.values
            .filter { $0.supportedTargetKinds.contains(target.kind) || $0.supportedTargetKinds.contains(.unknown) }
            .sorted { $0.id < $1.id }
        var observations: [LingShuCapabilityProbeObservation] = []
        for runner in runners {
            observations.append(contentsOf: await runner.probe(target))
        }
        return observations.sorted {
            if $0.status != $1.status {
                return statusRank($0.status) < statusRank($1.status)
            }
            return $0.confidence > $1.confidence
        }
    }

    private func statusRank(_ status: LingShuCapabilityProbeStatus) -> Int {
        switch status {
        case .available: return 0
        case .probable: return 1
        case .requiresAuth: return 2
        case .requiresDriver: return 3
        case .unknown: return 4
        case .unavailable: return 5
        case .unsafe: return 6
        }
    }
}
