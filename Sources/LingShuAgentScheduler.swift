import Foundation

struct LingShuAgentDispatch: Identifiable {
    let id = UUID()
    var task: CodexAgentTask
    var mode: AgentRuntimeMode
    var cadence: String
    var finding: String
    var load: Double
}

struct LingShuAgentSchedule {
    var dispatches: [LingShuAgentDispatch]
    var participatingAgents: [String]
    var hasExecutionAgent: Bool
    var preferredSupervisor: String

    var agentSummary: String {
        participatingAgents.joined(separator: "、")
    }
}

struct LingShuAgentScheduler {
    func makeSchedule(for route: CodexRoutePayload) -> LingShuAgentSchedule {
        let dispatches = route.agents.enumerated().map { offset, task in
            let mode = runtimeMode(for: task)
            return LingShuAgentDispatch(
                task: task,
                mode: mode,
                cadence: runtimeCadence(for: task, mode: mode),
                finding: runtimeFinding(for: task),
                load: min(0.92, 0.58 + Double(offset) * 0.05)
            )
        }

        let names = route.agents.map(\.agent)
        let selected = Set(names)
        let supervisor: String
        if selected.contains(LingShuCapabilityRole.review.rawValue) {
            supervisor = "审议"
        } else if selected.contains(LingShuCapabilityRole.monitoring.rawValue) {
            supervisor = "监控"
        } else if selected.contains(LingShuCapabilityRole.planning.rawValue) {
            supervisor = "规划"
        } else if selected.contains(LingShuCapabilityRole.design.rawValue) {
            supervisor = "设计"
        } else {
            supervisor = "路由"
        }

        return LingShuAgentSchedule(
            dispatches: dispatches,
            participatingAgents: names,
            hasExecutionAgent: selected.contains(LingShuCapabilityRole.execution.rawValue)
                || selected.contains(LingShuCapabilityRole.design.rawValue)
                || selected.contains(LingShuCapabilityRole.dispatch.rawValue),
            preferredSupervisor: supervisor
        )
    }

    func runtimeMode(for task: CodexAgentTask) -> AgentRuntimeMode {
        let rawMode = (task.mode ?? "").lowercased()
        let role = LingShuCapabilityRole.normalize(task.agent)

        if rawMode.contains("纠") {
            return .correcting
        }
        if rawMode.contains("验") || rawMode.contains("测") {
            return .verifying
        }
        if rawMode.contains("监") {
            return .supervising
        }
        if rawMode.contains("执") || rawMode.contains("开发") || rawMode.contains("实现") {
            return .working
        }
        if rawMode.contains("设计") {
            return role == .design ? .working : .planning
        }
        if rawMode.contains("规划") || rawMode.contains("计划") {
            return .planning
        }

        return role?.defaultMode ?? .planning
    }

    func runtimeCadence(for task: CodexAgentTask, mode: AgentRuntimeMode) -> String {
        if let cadence = task.cadence?.trimmingCharacters(in: .whitespacesAndNewlines), !cadence.isEmpty {
            return cadence
        }

        switch mode {
        case .working:
            return "实时"
        case .verifying:
            return "提交后"
        case .supervising:
            return agentCadence(task.agent)
        case .correcting:
            return "立即"
        default:
            return "本轮"
        }
    }

    func runtimeFinding(for task: CodexAgentTask) -> String {
        if let rationale = task.rationale?.trimmingCharacters(in: .whitespacesAndNewlines), !rationale.isEmpty {
            return rationale
        }

        return "已接收灵枢分派"
    }

    func agentCadence(_ agent: String) -> String {
        LingShuCapabilityRole.normalize(agent)?.defaultCadence ?? "-"
    }
}
