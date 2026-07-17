import Foundation

struct LingShuAgentRuntimeCounts: Equatable {
    var total: Int
    var online: Int
    var running: Int
    var pendingStart: Int

    var subtitle: String {
        "在线 \(online) · 运行 \(running) · 待启动 \(pendingStart)"
    }

    func subtitle(language: LingShuVoiceLanguage) -> String {
        language == .english
            ? "Online \(online) · Running \(running) · Standby \(pendingStart)"
            : subtitle
    }

    var statusText: String {
        "当前在线 \(online) 个 agent，运行 \(running) 个，待启动 \(pendingStart) 个。"
    }

    func statusText(language: LingShuVoiceLanguage) -> String {
        language == .english
            ? "\(online) agents online, \(running) running, \(pendingStart) on standby."
            : statusText
    }

    static func make(
        agents: [LingShuAgent],
        isModelConnected: Bool,
        canShowRuntime: Bool
    ) -> LingShuAgentRuntimeCounts {
        let total = agents.count
        let online = isModelConnected ? total : 0
        let running = canShowRuntime
            ? agents.filter { agent in
                agent.state == .running ||
                agent.mode != .dormant ||
                agent.lastFinding != "尚未巡检"
            }.count
            : 0
        let pendingStart = max(0, total - running)

        return .init(
            total: total,
            online: online,
            running: running,
            pendingStart: pendingStart
        )
    }
}
