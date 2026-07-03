import Foundation

@MainActor
extension LingShuState {
    /// 发布 MCP 只读控制面快照。
    ///
    /// 这是观测层的通用降耦:写操作和真实任务仍走 MainActor；外部测试/运维读取任务、聊天、
    /// 轨迹时可先读快照,避免演示、TTS 或长任务把控制面一起拖住。
    func publishControlSnapshot() {
        let hotIDs = Set(taskExecutionRecords.map(\.id))
        let lookup = taskExecutionRecords + archivedTaskExecutionRecords.filter { !hotIDs.contains($0.id) }
        let status: [String: Any] = [
            "coreState": coreStateDisplay,
            "loopPhase": loopPhase.rawValue,
            "loopVariant": agentLoopVariant.rawValue,
            "loopInvariantViolations": LingShuLoopInvariantTelemetry.total,
            "developmentFullAccess": developmentPhaseFullAccess,
            "goalSpecEnabled": goalSpecEnabled,
            "selfEvolutionEnabled": selfEvolutionEnabled,
            "trustScore": trustScore,
            "brainScore": [
                "score": brainScore.score,
                "completed": brainScore.completed,
                "fallbacks": brainScore.fallbacks,
                "brain": brainScore.brainID
            ],
            "missionTitle": missionTitle,
            "missionStatus": missionStatus,
            "autonomousPhase": autonomousRun.phase.rawValue,
            "autonomousObjective": autonomousRun.objective,
            "autonomousStatusLine": autonomousRun.statusLine,
            "standingPersonOnDuty": isStandingPersonOnDuty,
            "autoReactArmed": autonomousAutoReactArmed,
            "perceptionDigest": perceptionDigest,
            "perceptionDebug": perceptionDebugLine,
            "voiceListening": isListening,
            "voiceWake": voiceWakeListeningEnabled,
            "micSilentWarning": voiceManager?.micSilentWarning ?? "",
            "micLastInputAgoSec": voiceManager.map { Int(Date().timeIntervalSince($0.lastInputBufferAt)) } ?? -1,
            "previewState": [
                "isPresented": previewController.isPresented,
                "slideshow": previewController.slideshow,
                "pageIndex": previewController.pageIndex,
                "pageCount": previewController.pageCount,
                "title": previewController.title
            ],
            "recentSpoken": Array(recentSpokenLines.suffix(14)),
            "chatCount": chatMessages.count,
            "taskRecordCount": taskExecutionRecords.count,
            "queuedDispatchCount": queuedDispatchTasks.count,
            "activeDispatchedCount": dispatchedTaskBubbles.count,
            "pendingChatTurnCount": pendingChatTurnIDs.count,
            "recentTaskRecords": taskExecutionRecords.prefix(8).map { record in
                [
                    "title": record.title,
                    "status": record.status.rawValue,
                    "artifactCount": record.artifacts.count,
                    "artifacts": record.artifacts.map(\.location)
                ]
            }
        ]

        LingShuControlSnapshotStore.shared.update(
            status: status,
            records: lookup,
            feedback: taskRecordFeedback,
            chat: chatMessages,
            trace: executionTrace
        )
    }
}

