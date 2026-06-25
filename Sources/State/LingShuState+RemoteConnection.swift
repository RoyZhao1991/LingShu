import Foundation
import SwiftUI

@MainActor
extension LingShuState {
    var mainRemoteConnectionIndicatorColor: Color {
        if mainRemoteConnectionStatus.contains("断开") || mainRemoteConnectionStatus.contains("波动") {
            return .red
        }

        if mainRemoteConnectionStatus.contains("重连") || mainRemoteConnectionStatus.contains("探活") {
            return .orange
        }

        return .green
    }

    var mainRemoteConnectionIndicatorText: String {
        mainRemoteConnectionStatus.contains("断开") || mainRemoteConnectionStatus.contains("波动") ? "异常" : "正常"
    }

    func refreshRemoteSessionStatus() {
        let statusText = remoteSessionPool.stats().statusText
        if statusText != remoteSessionStatus {
            remoteSessionStatus = statusText
        }
    }

    func refreshMainRemoteConnectionStatus() {
        let snapshot = LingShuRemoteConnectionSnapshot(
            phase: remoteConnectionPolicy.phase(
                isProbeInFlight: isMainRemoteProbeInFlight,
                isGatewayConnected: isModelConnected,
                consecutiveFailures: mainRemoteConsecutiveFailures,
                hasSuccessfulProbe: mainRemoteLastSuccessAt != nil
            ),
            lastProbeAt: mainRemoteLastProbeAt,
            lastSuccessAt: mainRemoteLastSuccessAt,
            consecutiveFailures: mainRemoteConsecutiveFailures,
            lastFailureReason: mainRemoteLastFailureReason,
            lastDiagnosticLog: mainRemoteLastDiagnosticLog
        )

        if mainRemoteConnectionStatus != snapshot.statusText {
            mainRemoteConnectionStatus = snapshot.statusText
        }
        if mainRemoteConnectionDetail != snapshot.detailText {
            mainRemoteConnectionDetail = snapshot.detailText
        }
    }

    func tickMainRemoteConnectionGuard(now _: Date) {
        // codex-auth 远端会话保活已随 codex 模型通道下线;HTTP/API-Key 通道无持久远端会话,
        // 这里只刷新连接状态指示(由网关连通性派生),不再做后台探活。
        refreshMainRemoteConnectionStatus()
    }
}
