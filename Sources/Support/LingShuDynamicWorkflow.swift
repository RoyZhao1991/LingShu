import Foundation

/// Any execution stage may request human participation through this typed value.
/// OAuth remains a separate protocol and is intentionally not represented here.
struct LingShuHumanInteractionRequest: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Equatable, Sendable {
        case question
        case choice
        case form
        case qrCode = "qr_code"
        case externalLogin = "external_login"
        case physicalAction = "physical_action"
        case fileSelection = "file_selection"
        case confirmation
        case custom
    }

    struct Option: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var detail: String
        var value: String

        init(id: String = UUID().uuidString, label: String, detail: String = "", value: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
            self.value = value ?? label
        }
    }

    struct CompletionProbe: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case manual
            case httpStatus = "http_status"
            case fileExists = "file_exists"
        }

        var kind: Kind
        var target: String
        var expectedStatus: Int?
        var intervalSeconds: Double
        var timeoutSeconds: Double

        init(
            kind: Kind,
            target: String = "",
            expectedStatus: Int? = nil,
            intervalSeconds: Double = 2,
            timeoutSeconds: Double = 300
        ) {
            self.kind = kind
            self.target = target
            self.expectedStatus = expectedStatus
            self.intervalSeconds = min(max(intervalSeconds, 0.5), 30)
            self.timeoutSeconds = min(max(timeoutSeconds, 1), 86_400)
        }

        static func parse(_ raw: Any?) -> CompletionProbe? {
            guard let object = raw as? [String: Any] else { return nil }
            let rawKind = ((object["kind"] as? String) ?? (object["type"] as? String) ?? "manual")
                .lowercased().replacingOccurrences(of: "-", with: "_")
            guard let kind = Kind(rawValue: rawKind) else { return nil }
            return .init(
                kind: kind,
                target: ((object["target"] as? String) ?? (object["url"] as? String) ?? (object["path"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                expectedStatus: (object["expected_status"] as? Int) ?? (object["expectedStatus"] as? Int),
                intervalSeconds: Self.double(object["interval_seconds"] ?? object["intervalSeconds"]) ?? 2,
                timeoutSeconds: Self.double(object["timeout_seconds"] ?? object["timeoutSeconds"]) ?? 300
            )
        }

        private static func double(_ raw: Any?) -> Double? {
            if let value = raw as? Double { return value }
            if let value = raw as? Int { return Double(value) }
            if let value = raw as? NSNumber { return value.doubleValue }
            if let value = raw as? String { return Double(value) }
            return nil
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var prompt: String
    var payload: [String: String]
    var options: [Option]
    var completionProbe: CompletionProbe?
    var resumeToken: String?
    var source: String?

    init(
        id: String = UUID().uuidString,
        kind: Kind,
        title: String = "",
        prompt: String,
        payload: [String: String] = [:],
        options: [Option] = [],
        completionProbe: CompletionProbe? = nil,
        resumeToken: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.payload = payload
        self.options = options
        self.completionProbe = completionProbe
        self.resumeToken = resumeToken
        self.source = source
    }

    var normalized: LingShuHumanInteractionRequest? {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.options = options.filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !copy.prompt.isEmpty else { return nil }
        if copy.title.isEmpty { copy.title = copy.prompt }
        return copy
    }

    var choicePrompt: LingShuRouteChoicePrompt? {
        guard !options.isEmpty else { return nil }
        return LingShuRouteChoicePrompt(
            question: prompt,
            options: options.map { .init(label: $0.label, detail: $0.detail.isEmpty ? nil : $0.detail) }
        ).sanitized
    }

    static func parse(_ raw: Any?) -> LingShuHumanInteractionRequest? {
        guard let object = raw as? [String: Any] else { return nil }
        let rawKind = ((object["kind"] as? String) ?? (object["type"] as? String) ?? "question")
            .lowercased().replacingOccurrences(of: "-", with: "_")
        guard let kind = Kind(rawValue: rawKind) else { return nil }
        let prompt = ((object["prompt"] as? String)
                      ?? (object["question"] as? String)
                      ?? (object["message"] as? String)
                      ?? "")
        let options = ((object["options"] as? [Any]) ?? []).compactMap { item -> Option? in
            if let label = item as? String { return .init(label: label) }
            guard let option = item as? [String: Any],
                  let label = option["label"] as? String else { return nil }
            return .init(
                id: (option["id"] as? String) ?? UUID().uuidString,
                label: label,
                detail: (option["detail"] as? String) ?? "",
                value: option["value"] as? String
            )
        }
        var payload: [String: String] = [:]
        if let values = object["payload"] as? [String: Any] {
            for (key, value) in values {
                if let string = value as? String { payload[key] = string }
                else if let number = value as? NSNumber { payload[key] = number.stringValue }
            }
        }
        return LingShuHumanInteractionRequest(
            id: (object["id"] as? String) ?? UUID().uuidString,
            kind: kind,
            title: (object["title"] as? String) ?? "",
            prompt: prompt,
            payload: payload,
            options: options,
            completionProbe: CompletionProbe.parse(object["completion_probe"] ?? object["completionProbe"]),
            resumeToken: (object["resume_token"] as? String) ?? (object["resumeToken"] as? String),
            source: object["source"] as? String
        ).normalized
    }
}

enum LingShuWorkflowControlEvent: Codable, Equatable, Sendable {
    case requiresHumanInteraction(LingShuHumanInteractionRequest)
}

/// Transport for control events crossing model/tool/checker boundaries.
struct LingShuWorkflowControlEnvelope: Codable, Equatable, Sendable {
    static let prefix = "__LINGSHU_WORKFLOW_CONTROL__:"
    var event: LingShuWorkflowControlEvent

    var encodedPrompt: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString()
    }

    static func decode(from text: String) -> LingShuWorkflowControlEnvelope? {
        guard text.hasPrefix(prefix),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func extract(from text: String) -> LingShuWorkflowControlEnvelope? {
        decode(from: text) ?? firstEmbedded(in: text)?.envelope
    }

    static func firstEmbedded(in text: String) -> (range: Range<String.Index>, envelope: Self)? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        var end = prefixRange.upperBound
        while end < text.endIndex, isBase64Scalar(text[end]) { end = text.index(after: end) }
        let range = prefixRange.lowerBound..<end
        guard let envelope = decode(from: String(text[range])) else { return nil }
        return (range, envelope)
    }

    var humanInteraction: LingShuHumanInteractionRequest? {
        if case .requiresHumanInteraction(let request) = event { return request }
        return nil
    }

    var userFacingText: String {
        humanInteraction?.prompt ?? "这一步需要你参与后才能继续。"
    }

    private static func isBase64Scalar(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 48...57, 65...90, 97...122, 43, 47, 61: return true
        default: return false
        }
    }
}

enum LingShuWorkflowNodeStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case waitingForHuman = "waiting_for_human"
    case completed
    case failed
    case skipped
}

struct LingShuWorkflowNode: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var role: String
    var objective: String
    var dependencies: [String]
    var status: LingShuWorkflowNodeStatus
    var output: String?
    var failureReason: String?
    var humanInteraction: LingShuHumanInteractionRequest?
    var sessionID: String?
    var attempts: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        role: String,
        objective: String,
        dependencies: [String] = [],
        status: LingShuWorkflowNodeStatus = .pending,
        output: String? = nil,
        failureReason: String? = nil,
        humanInteraction: LingShuHumanInteractionRequest? = nil,
        sessionID: String? = nil,
        attempts: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.objective = objective
        self.dependencies = dependencies
        self.status = status
        self.output = output
        self.failureReason = failureReason
        self.humanInteraction = humanInteraction
        self.sessionID = sessionID
        self.attempts = attempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct LingShuWorkflowMutation: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Equatable, Sendable {
        case addNode = "add_node"
        case replaceNode = "replace_node"
        case removeNode = "remove_node"
        case replaceDependencies = "replace_dependencies"
        case retryNode = "retry_node"
        case skipNode = "skip_node"
    }

    var operation: Operation
    var node: LingShuWorkflowNode?
    var nodeID: String?
    var dependencies: [String]?
    var reason: String?

    static func parseList(_ json: String) -> [LingShuWorkflowMutation]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMutations = (root["mutations"] as? [[String: Any]])
                ?? (root["changes"] as? [[String: Any]]) else { return nil }
        let mutations: [LingShuWorkflowMutation] = rawMutations.compactMap { raw -> LingShuWorkflowMutation? in
            let operationText = ((raw["operation"] as? String) ?? (raw["op"] as? String) ?? "")
                .lowercased().replacingOccurrences(of: "-", with: "_")
            guard let operation = Operation(rawValue: operationText) else { return nil }
            let rawNode = raw["node"] as? [String: Any]
            let node: LingShuWorkflowNode? = rawNode.flatMap { value in
                let id = ((value["id"] as? String) ?? (value["name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = ((value["name"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
                let objective = ((value["objective"] as? String) ?? (value["goal"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !name.isEmpty, !objective.isEmpty else { return nil }
                let dependencies = (value["dependencies"] as? [String])
                    ?? (value["depends_on"] as? [String])
                    ?? []
                return LingShuWorkflowNode(
                    id: id,
                    name: name,
                    role: ((value["role"] as? String) ?? name).trimmingCharacters(in: .whitespacesAndNewlines),
                    objective: objective,
                    dependencies: dependencies
                )
            }
            return LingShuWorkflowMutation(
                operation: operation,
                node: node,
                nodeID: (raw["node_id"] as? String) ?? (raw["nodeID"] as? String) ?? (raw["id"] as? String),
                dependencies: (raw["dependencies"] as? [String]) ?? (raw["depends_on"] as? [String]),
                reason: raw["reason"] as? String
            )
        }
        // A mixed valid/invalid batch must not degrade into a partial graph rewrite. The brain
        // can correct and resubmit the whole transaction after seeing the validation response.
        guard mutations.count == rawMutations.count else { return nil }
        return mutations
    }
}

/// Opaque token attached to a human-interaction request raised inside a workflow node.
/// It lets the UI resume the exact role session and node without exposing routing details.
struct LingShuWorkflowResumeToken: Codable, Equatable, Sendable {
    static let prefix = "workflow:"
    var workflowID: String
    var nodeID: String
    var sessionID: String

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString()
    }

    static func decode(_ token: String?) -> LingShuWorkflowResumeToken? {
        guard let token, token.hasPrefix(prefix),
              let data = Data(base64Encoded: String(token.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Opaque continuation token for a verifier/checker that paused for human participation.
/// It is deliberately separate from OAuth and from workflow-node tokens: the UI can route
/// the answer back to the exact verification checkpoint without guessing from prose.
struct LingShuVerificationResumeToken: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Equatable, Sendable {
        case checkerSession = "checker_session"
        case deliveryReview = "delivery_review"
        case externalChecker = "external_checker"
    }

    static let prefix = "verification:"
    var id: String
    var mode: Mode
    var recordID: String?
    var scope: String

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString()
    }

    static func decode(_ token: String?) -> LingShuVerificationResumeToken? {
        guard let token, token.hasPrefix(prefix),
              let data = Data(base64Encoded: String(token.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct LingShuWorkflowRun: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Equatable, Sendable {
        case running
        case waitingForHuman = "waiting_for_human"
        case completed
        case failed
    }

    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case duplicateNode(String)
        case missingDependency(node: String, dependency: String)
        case cycle([String])

        var description: String {
            switch self {
            case .duplicateNode(let id): return "工作流节点重名: \(id)"
            case .missingDependency(let node, let dependency): return "节点「\(node)」依赖不存在的节点「\(dependency)」"
            case .cycle(let ids): return "工作流依赖成环: \(ids.joined(separator: " -> "))"
            }
        }
    }

    var id: String
    var taskRecordID: String?
    var goal: String
    var revision: Int
    var status: Status
    var nodes: [LingShuWorkflowNode]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = "workflow-\(UUID().uuidString)",
        taskRecordID: String? = nil,
        goal: String,
        revision: Int = 1,
        status: Status = .running,
        nodes: [LingShuWorkflowNode],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskRecordID = taskRecordID
        self.goal = goal
        self.revision = revision
        self.status = status
        self.nodes = nodes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        reconcileStatus()
    }

    var readyNodes: [LingShuWorkflowNode] {
        let completed = Set(nodes.filter { $0.status == .completed || $0.status == .skipped }.map(\.id))
        return nodes.filter { node in
            node.status == .pending && Set(node.dependencies).isSubset(of: completed)
        }
    }

    var waitingInteraction: LingShuHumanInteractionRequest? {
        nodes.first(where: { $0.status == .waitingForHuman })?.humanInteraction
    }

    var outputsByNodeID: [String: String] {
        Dictionary(uniqueKeysWithValues: nodes.compactMap { node in
            guard let output = node.output else { return nil }
            return (node.id, output)
        })
    }

    mutating func updateNode(
        _ id: String,
        status: LingShuWorkflowNodeStatus,
        output: String? = nil,
        failureReason: String? = nil,
        humanInteraction: LingShuHumanInteractionRequest? = nil,
        sessionID: String? = nil,
        now: Date = Date()
    ) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].status = status
        if let output { nodes[index].output = String(output.prefix(8_000)) }
        nodes[index].failureReason = failureReason
        nodes[index].humanInteraction = humanInteraction
        if let sessionID { nodes[index].sessionID = sessionID }
        if status == .running { nodes[index].attempts += 1 }
        nodes[index].updatedAt = now
        updatedAt = now
        reconcileStatus()
    }

    mutating func apply(_ mutations: [LingShuWorkflowMutation], now: Date = Date()) throws {
        var candidate = self
        for mutation in mutations {
            switch mutation.operation {
            case .addNode:
                guard var node = mutation.node else { continue }
                node.status = .pending
                candidate.nodes.append(node)
            case .replaceNode:
                guard let node = mutation.node,
                      let index = candidate.nodes.firstIndex(where: { $0.id == node.id }) else { continue }
                candidate.nodes[index] = node
            case .removeNode:
                guard let id = mutation.nodeID else { continue }
                candidate.nodes.removeAll { $0.id == id }
                for index in candidate.nodes.indices {
                    candidate.nodes[index].dependencies.removeAll { $0 == id }
                }
            case .replaceDependencies:
                guard let id = mutation.nodeID,
                      let index = candidate.nodes.firstIndex(where: { $0.id == id }) else { continue }
                candidate.nodes[index].dependencies = mutation.dependencies ?? []
            case .retryNode:
                guard let id = mutation.nodeID,
                      let index = candidate.nodes.firstIndex(where: { $0.id == id }) else { continue }
                candidate.nodes[index].status = .pending
                candidate.nodes[index].failureReason = nil
                candidate.nodes[index].humanInteraction = nil
            case .skipNode:
                guard let id = mutation.nodeID,
                      let index = candidate.nodes.firstIndex(where: { $0.id == id }) else { continue }
                candidate.nodes[index].status = .skipped
                candidate.nodes[index].failureReason = mutation.reason
            }
        }
        try candidate.validate()
        candidate.revision += 1
        candidate.updatedAt = now
        candidate.reconcileStatus()
        self = candidate
    }

    func validate() throws {
        var byID: [String: LingShuWorkflowNode] = [:]
        for node in nodes {
            if byID[node.id] != nil { throw ValidationError.duplicateNode(node.id) }
            byID[node.id] = node
        }
        for node in nodes {
            for dependency in node.dependencies where byID[dependency] == nil {
                throw ValidationError.missingDependency(node: node.id, dependency: dependency)
            }
        }
        var indegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set($0.dependencies).count) })
        var dependents: [String: [String]] = [:]
        for node in nodes {
            for dependency in Set(node.dependencies) { dependents[dependency, default: []].append(node.id) }
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while let id = queue.popLast() {
            visited += 1
            for dependent in dependents[id] ?? [] {
                indegree[dependent, default: 0] -= 1
                if indegree[dependent] == 0 { queue.append(dependent) }
            }
        }
        if visited != nodes.count {
            throw ValidationError.cycle(indegree.filter { $0.value > 0 }.map(\.key).sorted())
        }
    }

    mutating func reconcileStatus() {
        if nodes.contains(where: { $0.status == .waitingForHuman }) {
            status = .waitingForHuman
        } else if !nodes.isEmpty && nodes.allSatisfy({ $0.status == .completed || $0.status == .skipped }) {
            status = .completed
        } else if nodes.contains(where: { $0.status == .failed }) && readyNodes.isEmpty && !nodes.contains(where: { $0.status == .running }) {
            status = .failed
        } else {
            status = .running
        }
    }
}
