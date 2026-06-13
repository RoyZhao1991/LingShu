import Foundation

/// 对话页与运行态侧栏的状态派生值。
/// 这些值只组合现有状态，不承载路由、记忆或执行副作用。
@MainActor
extension LingShuState {
    var callChainSubtitle: String {
        "\(agentRuntimeCounts.subtitle) · \(taskQueueSummary)"
    }

    var taskQueueSummary: String {
        "线程 \(runningTaskThreadCount) / 排队 \(queuedTaskSegmentCount)"
    }

    var runningTaskThreadCount: Int {
        taskThreads.filter { $0.hasRunningSegment }.count
    }

    var queuedTaskSegmentCount: Int {
        taskThreads.reduce(0) { $0 + $1.queuedSegmentCount }
    }

    var visibleTaskThreads: [LingShuTaskThread] {
        Array(taskThreads.filter { $0.hasRunningSegment || $0.hasQueuedSegments }.prefix(6))
    }

    var agentRuntimeCounts: LingShuAgentRuntimeCounts {
        LingShuAgentRuntimeCounts.make(
            agents: agents,
            isModelConnected: isModelConnected,
            canShowRuntime: canShowAgentRuntime
        )
    }

    var coreStateDisplay: String {
        switch coreState {
        case .standby:
            return coreState.rawValue
        case .thinking:
            return "\(coreState.rawValue) \(formatElapsed(thinkingElapsedSeconds))"
        case .executing:
            if isModelExecuting || runtimePhase != .idle {
                return "\(coreState.rawValue) \(formatElapsed(executionElapsedSeconds))"
            }
            return coreState.rawValue
        case .abnormal:
            return "\(coreState.rawValue) \(formatElapsed(max(thinkingElapsedSeconds, executionElapsedSeconds)))"
        }
    }

    var coreStateSubtitle: String {
        switch coreState {
        case .standby:
            return "随时待命"
        case .thinking:
            return "已思考 \(thinkingElapsedText)"
        case .executing:
            return "已执行 \(executionElapsedText)"
        case .abnormal:
            return "异常持续 \(formatElapsed(max(thinkingElapsedSeconds, executionElapsedSeconds)))"
        }
    }

    var thinkingElapsedText: String {
        formatElapsed(thinkingElapsedSeconds)
    }

    var executionElapsedText: String {
        formatElapsed(executionElapsedSeconds)
    }

    var modelHeartbeatIdleText: String {
        formatElapsed(modelHeartbeatIdleSeconds)
    }
}
