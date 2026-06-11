import Foundation

enum LingShuExternalAgentTransport: String, Codable, CaseIterable {
    case local
    case http
    case a2a
    case mcp
}

struct LingShuExternalAgentDescriptor: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String
    var capabilities: [String]
    var transport: LingShuExternalAgentTransport
    var endpoint: String
    var isEnabled: Bool
}

struct LingShuExternalAgentRegistrySnapshot: Equatable {
    var registered: Int
    var enabled: Int
    var transports: [LingShuExternalAgentTransport]

    var statusText: String {
        "外部 agent 注册 \(registered) · 启用 \(enabled)"
    }
}

struct LingShuExternalAgentRequest: Codable, Equatable {
    var id: String
    var capability: String
    var prompt: String
    var contextSummary: String
    var permissionBoundary: String
    var heartbeatIntervalSeconds: Int
}

enum LingShuExternalAgentResponseStatus: String, Codable, Equatable {
    case accepted
    case running
    case succeeded
    case failed
    case rejected
    case timedOut
}

struct LingShuExternalAgentResponse: Codable, Equatable {
    var requestID: String
    var status: LingShuExternalAgentResponseStatus
    var summary: String
    var artifacts: [String]
    var risk: String?
}

struct LingShuExternalAgentInvocationPlan: Equatable {
    var agent: LingShuExternalAgentDescriptor
    var request: LingShuExternalAgentRequest

    var requiresNetwork: Bool {
        switch agent.transport {
        case .http, .a2a, .mcp:
            return true
        case .local:
            return false
        }
    }
}

final class LingShuExternalAgentRegistry {
    private var agents: [LingShuExternalAgentDescriptor]

    init(agents: [LingShuExternalAgentDescriptor] = []) {
        self.agents = agents
    }

    func register(_ descriptor: LingShuExternalAgentDescriptor) {
        if let index = agents.firstIndex(where: { $0.id == descriptor.id }) {
            agents[index] = descriptor
        } else {
            agents.append(descriptor)
        }
    }

    func enabledAgents(matching capability: String? = nil) -> [LingShuExternalAgentDescriptor] {
        agents.filter { agent in
            guard agent.isEnabled else { return false }
            guard let capability, !capability.isEmpty else { return true }
            return agent.capabilities.contains { $0.localizedCaseInsensitiveContains(capability) }
        }
    }

    func makeInvocationPlan(
        capability: String,
        prompt: String,
        contextSummary: String,
        permissionBoundary: String,
        heartbeatIntervalSeconds: Int = 15
    ) -> LingShuExternalAgentInvocationPlan? {
        guard let agent = enabledAgents(matching: capability).first else { return nil }

        let request = LingShuExternalAgentRequest(
            id: "external-\(UUID().uuidString)",
            capability: capability,
            prompt: prompt,
            contextSummary: contextSummary,
            permissionBoundary: permissionBoundary,
            heartbeatIntervalSeconds: heartbeatIntervalSeconds
        )

        return .init(agent: agent, request: request)
    }

    func snapshot() -> LingShuExternalAgentRegistrySnapshot {
        .init(
            registered: agents.count,
            enabled: agents.filter(\.isEnabled).count,
            transports: Array(Set(agents.map(\.transport))).sorted { $0.rawValue < $1.rawValue }
        )
    }
}
