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

    func tickMainRemoteConnectionGuard(now: Date) {
        refreshMainRemoteConnectionStatus()

        guard usesCodexAuth else { return }
        guard codexAuthStatus == "已登录" else { return }

        if remoteConnectionPolicy.shouldProbe(
            now: now,
            lastProbeAt: mainRemoteLastProbeAt,
            isProbeInFlight: isMainRemoteProbeInFlight,
            hasActiveModelCall: hasActiveModelCall,
            isGatewayConnected: isModelConnected,
            consecutiveFailures: mainRemoteConsecutiveFailures
        ) {
            performMainRemoteHealthProbe(reason: mainRemoteLastSuccessAt == nil ? "启动探活" : "定时保活")
        }
    }

    func performMainRemoteHealthProbe(reason: String, force: Bool = false) {
        let now = Date()
        guard usesCodexAuth, codexAuthStatus == "已登录" else { return }
        guard remoteConnectionPolicy.shouldProbe(
            now: now,
            lastProbeAt: mainRemoteLastProbeAt,
            isProbeInFlight: isMainRemoteProbeInFlight,
            hasActiveModelCall: hasActiveModelCall,
            isGatewayConnected: isModelConnected,
            consecutiveFailures: mainRemoteConsecutiveFailures,
            force: force
        ) else { return }

        let cliPath = codexCLIPath
        let model = modelName
        let workingDirectory = codexWorkingDirectory
        let permissionMode = codexPermissionMode
        let fastMode = codexFastMode
        let timeout = min(max(30.0, codexTimeoutSeconds / 3), 90.0)
        let memoryPromptHint = mainThreadKernel.promptHint(baseMemory: "主线程远端探活，不创建任务线程。")
        let lease = remoteSessionPool.lease(
            provider: modelProvider,
            model: model,
            purpose: .mainRouting,
            contextKey: mainThreadKernel.snapshot.sessionID,
            workingDirectory: workingDirectory,
            permissionBoundary: mainRoutingPermissionBoundary,
            endpoint: endpoint,
            protocolName: "Codex CLI",
            localContextSummary: memoryPromptHint
        )

        mainRemoteProbeRunID += 1
        let probeRunID = mainRemoteProbeRunID
        let handle = CodexExecutionHandle()
        activeHealthProbeHandle = handle
        isMainRemoteProbeInFlight = true
        mainRemoteLastProbeAt = now
        refreshRemoteSessionStatus()
        refreshMainRemoteConnectionStatus()

        DispatchQueue.global(qos: .utility).async {
            let result = CodexBridge.healthProbe(
                preferredPath: cliPath,
                modelName: model,
                workingDirectory: workingDirectory,
                permissionMode: permissionMode,
                timeout: timeout,
                fastMode: fastMode,
                remoteSessionID: lease.nativeSessionID,
                cancellation: handle,
                progress: { chunk in
                    Task { @MainActor in
                        guard self.mainRemoteProbeRunID == probeRunID else { return }
                        self.appendCodexStream(chunk, actor: "主线程守护")
                    }
                },
                sessionRegistrar: { sessionID in
                    Task { @MainActor in
                        guard self.mainRemoteProbeRunID == probeRunID else { return }
                        self.remoteSessionPool.resolveNativeSession(
                            lease: lease,
                            nativeSessionID: sessionID,
                            localContextSummary: memoryPromptHint
                        )
                        self.refreshRemoteSessionStatus()
                    }
                }
            )

            DispatchQueue.main.async {
                guard self.mainRemoteProbeRunID == probeRunID else { return }
                if self.activeHealthProbeHandle === handle {
                    self.activeHealthProbeHandle = nil
                }
                self.isMainRemoteProbeInFlight = false
                self.mainRemoteLastProbeAt = Date()

                switch result {
                case .success(let report):
                    let hadFailures = self.mainRemoteConsecutiveFailures > 0
                    self.mainRemoteConsecutiveFailures = 0
                    self.mainRemoteLastSuccessAt = Date()
                    self.mainRemoteLastFailureReason = ""
                    self.mainRemoteLastDiagnosticLog = CodexDiagnosticLogFilter.diagnosticSummary(from: report.rawLog)
                    self.remoteSessionPool.resolveNativeSession(
                        lease: lease,
                        nativeSessionID: lease.nativeSessionID,
                        localContextSummary: memoryPromptHint
                    )
                    self.recordModelHeartbeat(source: "主线程守护", detail: "主线程远端探活成功。", isSynthetic: false)
                    if hadFailures || force {
                        self.logEvent("现在  主线程远端会话已恢复。")
                    }

                case .failure(let failure):
                    self.mainRemoteConsecutiveFailures += 1
                    self.mainRemoteLastFailureReason = failure.message
                    self.mainRemoteLastDiagnosticLog = failure.diagnosticSummary
                    self.remoteSessionPool.markFailed(lease: lease)

                    if self.remoteConnectionPolicy.isDisconnected(consecutiveFailures: self.mainRemoteConsecutiveFailures) {
                        self.logEvent("现在  主线程远端会话断开：\(failure.message)")
                        if !self.hasActiveModelCall {
                            self.missionTitle = "主通道断开"
                            self.missionStatus = "主线程远端会话连续探活失败。我会继续自动重连，恢复前不会伪造模型判断。"
                            self.enterCoreState(.abnormal, resetTimer: false)
                        }
                    }
                }

                self.refreshRemoteSessionStatus()
                self.refreshMainRemoteConnectionStatus()
            }
        }
    }
}
