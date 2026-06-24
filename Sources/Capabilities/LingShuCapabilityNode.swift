import Foundation

/// A capability node is the stable, schedulable unit of LingShu's thin-kernel architecture.
/// Concrete abilities such as PPT generation, browser automation, TTS, MCP tools and devices
/// should be represented here before the task system treats them as usable.
enum LingShuCapabilityNodeKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case kernel
    case document
    case browser
    case voiceInput
    case voiceOutput
    case vision
    case perception
    case memory
    case scheduler
    case computerControl
    case externalAgent
    case mcpTool
    case skill
    case device
    case model
    case plugin
    case generatedAdapter
    case unknown
}

enum LingShuCapabilityDataType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case text
    case markdown
    case pdf
    case presentation
    case document
    case spreadsheet
    case image
    case audio
    case video
    case json
    case command
    case ui
    case deviceSignal
    case task
    case any
}

enum LingShuCapabilityPermission: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case none
    case readLocalFiles
    case writeLocalFiles
    case runCommand
    case network
    case externalAccount
    case sendExternal
    case payment
    case microphone
    case camera
    case speaker
    case screenCapture
    case computerControl
    case physicalDevice
    case systemChange
    case selfModify
}

enum LingShuCapabilityRisk: String, Codable, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    case low
    case medium
    case high
    case critical

    static func < (lhs: LingShuCapabilityRisk, rhs: LingShuCapabilityRisk) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ value: LingShuCapabilityRisk) -> Int {
        switch value {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}

enum LingShuCapabilityNodeStatus: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case discovered
    case needsAuth
    case needsDriver
    case verifying
    case verified
    case failed
    case unavailable
    case disabled

    var isSchedulable: Bool { self == .verified }
}

enum LingShuCapabilityVerificationProbeKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case fileRoundTrip
    case commandExitZero
    case apiHealth
    case toolCall
    case audioPlayback
    case audioTranscription
    case imageUnderstanding
    case browserDOM
    case deviceReadback
    case userConfirmation
}

struct LingShuCapabilityVerificationProbe: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: LingShuCapabilityVerificationProbeKind
    var summary: String
    var commandHint: String?
    var requiredEvidence: [String]

    init(
        id: String = UUID().uuidString,
        kind: LingShuCapabilityVerificationProbeKind,
        summary: String,
        commandHint: String? = nil,
        requiredEvidence: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.commandHint = commandHint
        self.requiredEvidence = requiredEvidence
    }
}

struct LingShuCapabilityNode: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: LingShuCapabilityNodeKind
    var verb: LingShuCapabilityVerb?
    var inputTypes: [LingShuCapabilityDataType]
    var outputTypes: [LingShuCapabilityDataType]
    var requiredPermissions: [LingShuCapabilityPermission]
    var risk: LingShuCapabilityRisk
    var source: String
    var adapterID: String?
    var status: LingShuCapabilityNodeStatus
    var verificationProbe: LingShuCapabilityVerificationProbe?
    var lastVerifiedAt: Date?
    var description: String
    var tags: [String]

    init(
        id: String,
        name: String,
        kind: LingShuCapabilityNodeKind,
        verb: LingShuCapabilityVerb? = nil,
        inputTypes: [LingShuCapabilityDataType] = [.any],
        outputTypes: [LingShuCapabilityDataType] = [.any],
        requiredPermissions: [LingShuCapabilityPermission] = [],
        risk: LingShuCapabilityRisk = .low,
        source: String,
        adapterID: String? = nil,
        status: LingShuCapabilityNodeStatus = .discovered,
        verificationProbe: LingShuCapabilityVerificationProbe? = nil,
        lastVerifiedAt: Date? = nil,
        description: String,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.verb = verb
        self.inputTypes = inputTypes
        self.outputTypes = outputTypes
        self.requiredPermissions = requiredPermissions
        self.risk = risk
        self.source = source
        self.adapterID = adapterID
        self.status = status
        self.verificationProbe = verificationProbe
        self.lastVerifiedAt = lastVerifiedAt
        self.description = description
        self.tags = tags
    }

    var isSchedulable: Bool {
        status.isSchedulable
    }

    var permissionSummary: String {
        requiredPermissions.isEmpty ? "none" : requiredPermissions.map(\.rawValue).joined(separator: ",")
    }
}

struct LingShuCapabilityLifecycleEvent: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var nodeID: String
    var from: LingShuCapabilityNodeStatus?
    var to: LingShuCapabilityNodeStatus
    var reason: String
    var evidence: [String]
    var at: Date

    init(
        id: String = UUID().uuidString,
        nodeID: String,
        from: LingShuCapabilityNodeStatus? = nil,
        to: LingShuCapabilityNodeStatus,
        reason: String,
        evidence: [String] = [],
        at: Date = Date()
    ) {
        self.id = id
        self.nodeID = nodeID
        self.from = from
        self.to = to
        self.reason = reason
        self.evidence = evidence
        self.at = at
    }
}

struct LingShuCapabilityLifecycleReport: Codable, Sendable, Equatable {
    var nodes: [LingShuCapabilityNode]
    var events: [LingShuCapabilityLifecycleEvent]

    var schedulableNodes: [LingShuCapabilityNode] {
        nodes.filter(\.isSchedulable)
    }

    var blockedNodes: [LingShuCapabilityNode] {
        nodes.filter { !$0.isSchedulable }
    }

    func node(id: String) -> LingShuCapabilityNode? {
        nodes.first { $0.id == id }
    }
}

enum LingShuCapabilityNodeRegistry {
    static func merge(_ groups: [[LingShuCapabilityNode]]) -> [LingShuCapabilityNode] {
        var seen = Set<String>()
        var output: [LingShuCapabilityNode] = []
        for node in groups.flatMap({ $0 }) {
            guard !seen.contains(node.id) else { continue }
            seen.insert(node.id)
            output.append(node)
        }
        return output.sorted { left, right in
            if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
            return left.name < right.name
        }
    }

    static func graphEntry(from node: LingShuCapabilityNode) -> LingShuCapabilityEntry? {
        guard let verb = node.verb else { return nil }
        let permission: LingShuCapabilityPermissionState
        switch node.status {
        case .verified:
            permission = .granted
        case .needsAuth:
            permission = .needsAuth
        case .disabled, .failed, .unavailable:
            permission = .denied
        default:
            permission = .unknown
        }
        return LingShuCapabilityEntry(
            id: node.id,
            verb: verb,
            description: node.description,
            source: node.source,
            online: node.status != .unavailable && node.status != .disabled,
            permission: permission,
            verified: node.status == .verified,
            lastVerifiedAt: node.lastVerifiedAt
        )
    }

    static func node(
        from capability: LingShuCapability,
        status: LingShuCapabilityNodeStatus = .verified,
        verifiedAt: Date? = nil
    ) -> LingShuCapabilityNode {
        let kind: LingShuCapabilityNodeKind
        switch capability.source {
        case "mcp": kind = .mcpTool
        case "skill": kind = .skill
        case "team": kind = .externalAgent
        case "authored": kind = .generatedAdapter
        case "external": kind = .externalAgent
        default: kind = .plugin
        }
        let verb = LingShuCapabilityVerb.infer(
            id: capability.id,
            description: capability.description,
            source: capability.source
        )
        return LingShuCapabilityNode(
            id: capability.id,
            name: capability.description,
            kind: kind,
            verb: verb,
            inputTypes: [.task],
            outputTypes: [.any],
            requiredPermissions: capability.source == "mcp" ? [.network] : [],
            risk: capability.source == "mcp" ? .medium : .low,
            source: capability.source,
            adapterID: capability.id,
            status: status,
            verificationProbe: .init(kind: .toolCall, summary: "调用一次并确认返回合法结果"),
            lastVerifiedAt: verifiedAt,
            description: capability.description,
            tags: [capability.source]
        )
    }

    static func node(from entry: LingShuCapabilityEntry) -> LingShuCapabilityNode {
        let status: LingShuCapabilityNodeStatus
        if entry.usable {
            status = .verified
        } else if entry.permission == .needsAuth {
            status = .needsAuth
        } else if entry.online {
            status = .discovered
        } else {
            status = .unavailable
        }
        return LingShuCapabilityNode(
            id: entry.id,
            name: entry.description,
            kind: entry.source == "authored" ? .generatedAdapter : .plugin,
            verb: entry.verb,
            inputTypes: [.task],
            outputTypes: [.any],
            requiredPermissions: entry.permission == .needsAuth ? [.externalAccount] : [],
            risk: entry.permission == .needsAuth ? .medium : .low,
            source: entry.source,
            adapterID: entry.id,
            status: status,
            verificationProbe: .init(kind: .toolCall, summary: "最小验证:真实调用一次并获得合法结果"),
            lastVerifiedAt: entry.lastVerifiedAt,
            description: entry.description,
            tags: [entry.source]
        )
    }

    static func node(from observation: LingShuCapabilityProbeObservation) -> LingShuCapabilityNode {
        let status: LingShuCapabilityNodeStatus
        switch observation.status {
        case .available, .probable:
            status = .discovered
        case .requiresAuth:
            status = .needsAuth
        case .requiresDriver:
            status = .needsDriver
        case .unavailable:
            status = .unavailable
        case .unsafe:
            status = .failed
        case .unknown:
            status = .discovered
        }
        return LingShuCapabilityNode(
            id: "probe:\(observation.capabilityID)",
            name: observation.description,
            kind: .plugin,
            verb: LingShuCapabilityVerb.parse(observation.verb),
            inputTypes: [.task],
            outputTypes: [.any],
            requiredPermissions: status == .needsAuth ? [.externalAccount] : [],
            risk: status == .needsDriver ? .high : (status == .needsAuth ? .medium : .low),
            source: "probe:\(observation.targetID)",
            adapterID: observation.capabilityID,
            status: status,
            verificationProbe: .init(kind: .toolCall, summary: "探测后做最小安全调用验证"),
            lastVerifiedAt: nil,
            description: observation.description,
            tags: observation.evidence
        )
    }
}
