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

    /// 工具中文显示名(用于加载气泡"执行中：…"的实时进展)。
    nonisolated static func toolDisplayName(_ tool: String) -> String {
        switch tool {
        case "write_file": return "写文件"
        case "edit_file": return "改文件"
        case "read_file": return "读文件"
        case "list_directory": return "列目录"
        case "fetch_url": return "抓网页"
        case "run_command": return "跑命令"
        case "web_search": return "联网搜索"
        case "apply_skill": return "调取技能"
        case "recall_memory": return "召回记忆"
        case "remember_credential": return "存凭据"
        case "list_credentials": return "列凭据"
        case "watch_until": return "后台守候"
        case "list_watches": return "列守候"
        case "cancel_watch": return "撤守候"
        case "get_current_time": return "查时间"
        default:
            if let computer = computerToolDisplayName(tool) { return computer }
            return tool.hasPrefix("mcp:") ? String(tool.dropFirst(4)) : tool
        }
    }

    // MARK: - 本轮真实进展（侧栏绑真实进展,替代静态聚合遥测,计划 §2）

    /// 当前这轮正在写入的任务记录:独立运行时取其记录,否则模型在跑时取最近更新的记录。无活动 → nil。
    var currentTaskRecord: LingShuTaskExecutionRecord? {
        if autonomousRun.isActive, let id = autonomousRunRecordID {
            return taskExecutionRecords.first { $0.id == id }
        }
        guard hasActiveModelCall else { return nil }
        return taskExecutionRecords
            .filter { $0.status == .running || $0.status == .queued }
            .max(by: { $0.updatedAt < $1.updatedAt })
            ?? taskExecutionRecords.max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// 本轮是否真有活在跑(决定侧栏显示进展还是有意义的空态)。
    var hasLiveProgress: Bool {
        autonomousRun.isActive || hasActiveModelCall || currentTaskRecord != nil
    }

    /// 正在调用的工具(从当前记录尾部的 toolCall 取),返回「显示名 · 一句话摘要」。无则 nil。
    var currentToolDisplay: String? {
        guard let record = currentTaskRecord else { return nil }
        for message in record.messages.reversed() {
            if case let .toolCall(tool, summary, _) = message.detail {
                let name = Self.toolDisplayName(tool)
                let brief = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return brief.isEmpty ? name : "\(name) · \(brief.prefix(40))"
            }
        }
        return nil
    }

    /// 独立运行当前正在执行的 runbook 步(序号 / 总数 / 步)。非运行中或无 runbook → nil。
    var autonomousRunningStep: (index: Int, total: Int, step: LingShuAutonomousRunbookStep)? {
        guard autonomousRun.isActive, let runbook = autonomousRun.runbook else { return nil }
        guard let idx = runbook.steps.firstIndex(where: { $0.status == .running })
            ?? runbook.steps.firstIndex(where: { $0.status == .waiting }) else { return nil }
        return (idx + 1, runbook.steps.count, runbook.steps[idx])
    }

    /// 本轮已用时:独立运行从其 startedAt 起算,否则用中枢思考/执行计时。无活动 → nil。
    var currentRoundElapsed: String? {
        if autonomousRun.isActive, let startedAt = autonomousRun.startedAt {
            return formatElapsed(Int(Date().timeIntervalSince(startedAt)))
        }
        guard hasActiveModelCall else { return nil }
        switch coreState {
        case .executing, .abnormal: return executionElapsedText
        case .thinking: return thinkingElapsedText
        case .standby: return nil
        }
    }

    /// 当前任务记录的计划完成度(已完成 / 总步数)。无计划 → nil。
    var currentPlanProgress: (done: Int, total: Int)? {
        guard let plan = currentTaskRecord?.plan, !plan.isEmpty else { return nil }
        return (plan.filter { $0.status == .completed }.count, plan.count)
    }

    /// 执行轨迹尾部:当前记录最近的工具/文件/结果消息(最新在后),供侧栏渲染"它在干嘛"。
    var recentExecutionMessages: [LingShuTaskExecutionMessage] {
        guard let record = currentTaskRecord else { return [] }
        return Array(record.messages.suffix(6))
    }
}
