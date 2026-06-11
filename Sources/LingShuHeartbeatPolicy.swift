import Foundation

struct LingShuHeartbeatPolicy: Equatable {
    var syntheticHeartbeatInterval: TimeInterval
    var idleTimeout: TimeInterval

    init(
        syntheticHeartbeatInterval: TimeInterval = 15,
        idleTimeout: TimeInterval
    ) {
        self.syntheticHeartbeatInterval = syntheticHeartbeatInterval
        self.idleTimeout = idleTimeout
    }

    func shouldEmitSyntheticHeartbeat(
        processIsRunning: Bool,
        lastSyntheticHeartbeatAt: Date,
        now: Date
    ) -> Bool {
        processIsRunning && now.timeIntervalSince(lastSyntheticHeartbeatAt) >= syntheticHeartbeatInterval
    }

    func shouldDeclareHeartbeatLost(
        processIsRunning: Bool,
        lastActivityAt: Date,
        now: Date
    ) -> Bool {
        processIsRunning && now.timeIntervalSince(lastActivityAt) >= idleTimeout
    }
}
