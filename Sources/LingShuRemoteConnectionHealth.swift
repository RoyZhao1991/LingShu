import Foundation

enum LingShuRemoteConnectionPhase: String, Codable, Equatable {
    case cold = "未探活"
    case probing = "探活中"
    case warm = "常驻活跃"
    case reconnecting = "自动重连"
    case degraded = "链路波动"
    case disconnected = "连接断开"
}

struct LingShuRemoteConnectionSnapshot: Equatable {
    var phase: LingShuRemoteConnectionPhase
    var lastProbeAt: Date?
    var lastSuccessAt: Date?
    var consecutiveFailures: Int
    var lastFailureReason: String
    var lastDiagnosticLog: String

    var statusText: String {
        switch phase {
        case .cold:
            return "未探活"
        case .probing:
            return "探活中"
        case .warm:
            return "常驻活跃"
        case .reconnecting:
            return "自动重连 \(consecutiveFailures)"
        case .degraded:
            return "链路波动"
        case .disconnected:
            return "已断开 \(consecutiveFailures)"
        }
    }

    var detailText: String {
        if phase == .disconnected, !lastFailureReason.isEmpty {
            return lastFailureReason
        }

        if let lastSuccessAt {
            return "最近成功：\(Self.timeFormatter.string(from: lastSuccessAt))"
        }

        if let lastProbeAt {
            return "最近探活：\(Self.timeFormatter.string(from: lastProbeAt))"
        }

        return "等待主线程远端探活"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct LingShuRemoteConnectionPolicy: Equatable {
    var probeInterval: TimeInterval
    var reconnectInterval: TimeInterval
    var failureThreshold: Int

    init(
        probeInterval: TimeInterval = 60,
        reconnectInterval: TimeInterval = 15,
        failureThreshold: Int = 3
    ) {
        self.probeInterval = probeInterval
        self.reconnectInterval = reconnectInterval
        self.failureThreshold = max(1, failureThreshold)
    }

    func shouldProbe(
        now: Date,
        lastProbeAt: Date?,
        isProbeInFlight: Bool,
        hasActiveModelCall: Bool,
        isGatewayConnected: Bool,
        consecutiveFailures: Int,
        force: Bool = false
    ) -> Bool {
        guard isGatewayConnected, !isProbeInFlight, !hasActiveModelCall else { return false }
        if force { return true }

        guard let lastProbeAt else { return true }
        let interval = consecutiveFailures > 0 ? reconnectInterval : probeInterval
        return now.timeIntervalSince(lastProbeAt) >= interval
    }

    func phase(
        isProbeInFlight: Bool,
        isGatewayConnected: Bool,
        consecutiveFailures: Int,
        hasSuccessfulProbe: Bool
    ) -> LingShuRemoteConnectionPhase {
        guard isGatewayConnected else { return .disconnected }
        if isProbeInFlight { return .probing }
        if consecutiveFailures >= failureThreshold { return .disconnected }
        if consecutiveFailures > 0 { return .reconnecting }
        return hasSuccessfulProbe ? .warm : .cold
    }

    func isDisconnected(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= failureThreshold
    }
}
