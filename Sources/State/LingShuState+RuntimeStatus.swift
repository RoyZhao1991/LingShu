import Foundation

struct LingShuTaskProgressDiagnostic: Equatable {
    var phase: String
    var headline: String
    var detail: String
    var lastTrace: String?
    var lastTraceTime: String
    var currentStep: String
    var waitState: String
    var heartbeatText: String
    var recordIDShort: String
    var isStale: Bool
    var isTerminalButLoading: Bool
}

/// 对话页与运行态侧栏的状态派生值。
/// 这些值只组合现有状态，不承载路由、记忆或执行副作用。
@MainActor
extension LingShuState {
    var callChainSubtitle: String {
        "\(agentRuntimeCounts.subtitle(language: language)) · \(taskQueueSummary)"
    }

    var taskQueueSummary: String {
        loc(
            "线程 \(runningTaskThreadCount) / 排队 \(queuedTaskSegmentCount)",
            "Threads \(runningTaskThreadCount) / Queued \(queuedTaskSegmentCount)"
        )
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
        // 跑任务时优先显示更细的 LOOP 环节(理解/规划/执行/验收中),让用户看得到当前在干什么、别干等。国际化:按当前语言。
        let phaseName = loc(loopPhase.rawValue, loopPhase.englishName)
        let stateName = loc(coreState.rawValue, coreState.englishName)
        if loopPhase.isActive {
            switch coreState {
            case .thinking: return "\(phaseName) \(formatElapsed(thinkingElapsedSeconds))"
            case .executing: return "\(phaseName) \(formatElapsed(executionElapsedSeconds))"
            default: return phaseName
            }
        }
        switch coreState {
        case .standby:
            return stateName
        case .thinking:
            return "\(stateName) \(formatElapsed(thinkingElapsedSeconds))"
        case .executing:
            if isModelExecuting || runtimePhase != .idle {
                return "\(stateName) \(formatElapsed(executionElapsedSeconds))"
            }
            return stateName
        case .abnormal:
            return "\(stateName) \(formatElapsed(max(thinkingElapsedSeconds, executionElapsedSeconds)))"
        }
    }

    var coreStateSubtitle: String {
        switch coreState {
        case .standby:
            return loc("随时待命", "Ready")
        case .thinking:
            return loc("已思考 \(thinkingElapsedText)", "Thinking \(thinkingElapsedText)")
        case .executing:
            return loc("已执行 \(executionElapsedText)", "Running \(executionElapsedText)")
        case .abnormal:
            return loc(
                "异常持续 \(formatElapsed(max(thinkingElapsedSeconds, executionElapsedSeconds)))",
                "Issue for \(formatElapsed(max(thinkingElapsedSeconds, executionElapsedSeconds)))"
            )
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
        case "update_plan": return "制定规划"
        case "review_design": return "审版式"
        case "find_images": return "找配图"
        case "acquire_resource": return "找素材"
        case "discover_skill": return "找技能"
        case "spawn_task": return "派子任务"
        case "ask_user": return "待你确认"
        case "speak": return "讲述"
        case "open_preview": return "打开预览"
        case "preview_next", "preview_prev", "preview_goto": return "翻页"
        case "preview_scroll": return "滚动浏览"
        case "close_preview": return "关闭预览"
        default:
            if let computer = computerToolDisplayName(tool) { return computer }
            return tool.hasPrefix("mcp:") ? String(tool.dropFirst(4)) : tool
        }
    }

    nonisolated static func toolDisplayName(_ tool: String, language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return toolDisplayName(tool) }
        switch tool {
        case "write_file": return "Write file"
        case "edit_file": return "Edit file"
        case "read_file": return "Read file"
        case "list_directory": return "List directory"
        case "fetch_url": return "Fetch page"
        case "run_command": return "Run command"
        case "web_search": return "Web search"
        case "apply_skill": return "Use skill"
        case "recall_memory": return "Recall memory"
        case "remember_credential": return "Save credential"
        case "list_credentials": return "List credentials"
        case "watch_until": return "Wait in background"
        case "list_watches": return "List watches"
        case "cancel_watch": return "Cancel watch"
        case "get_current_time": return "Get time"
        case "update_plan": return "Update plan"
        case "review_design": return "Review design"
        case "find_images": return "Find images"
        case "acquire_resource": return "Acquire resource"
        case "discover_skill": return "Discover skill"
        case "spawn_task": return "Dispatch task"
        case "ask_user": return "Waiting for confirmation"
        case "speak": return "Speak"
        case "open_preview": return "Open preview"
        case "preview_next", "preview_prev", "preview_goto": return "Change page"
        case "preview_scroll": return "Scroll preview"
        case "close_preview": return "Close preview"
        default:
            return tool.hasPrefix("mcp:") ? String(tool.dropFirst(4)) : tool
        }
    }

    /// 当前在干什么(给加载气泡用,替代笼统的"思考中"):优先显示**进行中的计划步**(模型写的步骤名正是
    /// "生成PPT/写测试/制定规划"这种活动级标签),没有进行中就显示首个待办步,再没有则"推进中"。
    var currentActivityLabel: String {
        if let rid = currentAgentTurnRecordID ?? autonomousRunRecordID,
           let rec = taskExecutionRecords.first(where: { $0.id == rid }) {
            if let s = rec.plan.first(where: { $0.status == .inProgress }) { return String(s.title.prefix(22)) }
            if let s = rec.plan.first(where: { $0.status == .pending }) { return String(s.title.prefix(22)) }
        }
        return "推进中"
    }

    /// **per-task** 活动标签(给加载气泡用,**不串全局**):只看**该条记录自己**的计划进行中步/待办步;
    /// 没有计划则按该记录状态给通用活动。多任务并行时每个气泡显示各自进度,不再借用全局 missionTitle 而串台。
    func activityLabel(for recordID: String?) -> String {
        guard let recordID, let rec = taskExecutionRecords.first(where: { $0.id == recordID }) else { return "理解需求" }
        if let s = rec.plan.first(where: { $0.status == .inProgress }) { return String(s.title.prefix(22)) }
        if let s = rec.plan.first(where: { $0.status == .pending }) { return String(s.title.prefix(22)) }
        switch rec.status {
        case .running: return "推进中"
        case .queued: return "排队中"
        default: return "理解需求"
        }
    }

    /// 加载气泡的可解释运行态：把任务账本、计划、最近结构化消息和 trace 合成一行可读诊断。
    /// 目的不是替代任务窗口，而是在长时间推进时让主界面至少知道“卡在什么环节”。
    func activityDiagnostic(for recordID: String?, now: Date = Date()) -> LingShuTaskProgressDiagnostic? {
        guard let recordID, let record = taskExecutionRecords.first(where: { $0.id == recordID }) else { return nil }
        let commit = record.threadCommit
        let heartbeatAt = commit?.lastHeartbeatAt ?? record.updatedAt
        let heartbeatAge = max(0, Int(now.timeIntervalSince(heartbeatAt)))
        let isTerminal = record.status.isTerminal
        let isStale = !isTerminal && heartbeatAge >= 60
        let phase = activityDiagnosticPhase(commit?.phase, status: record.status)
        let headline = activityDiagnosticHeadline(record, heartbeatAge: heartbeatAge, isStale: isStale)
        let detail = activityDiagnosticDetail(record)
        let traceEvent = activityDiagnosticMatchedTrace(recordID: recordID, record: record)
        let trace = activityDiagnosticTrace(from: traceEvent)
        let heartbeatLabel = isTerminal ? "更新" : "心跳"

        return LingShuTaskProgressDiagnostic(
            phase: phase,
            headline: headline,
            detail: detail,
            lastTrace: trace,
            lastTraceTime: traceEvent?.displayTime ?? "无",
            currentStep: activityDiagnosticCurrentStep(record),
            waitState: activityDiagnosticWaitState(record),
            heartbeatText: "\(heartbeatLabel) \(formatElapsed(heartbeatAge)) 前",
            recordIDShort: String(record.id.suffix(8)),
            isStale: isStale,
            isTerminalButLoading: isTerminal
        )
    }

    private func activityDiagnosticPhase(
        _ phase: LingShuTaskThreadCommit.Phase?,
        status: LingShuTaskExecutionStatus
    ) -> String {
        let resolved = phase ?? LingShuTaskThreadCommit.phase(for: status)
        switch resolved {
        case .planning: return "规划"
        case .executing: return "执行"
        case .checking: return "验收"
        case .delivering: return "交付"
        case .waiting: return "等待"
        case .failed: return "失败"
        }
    }

    private func activityDiagnosticHeadline(
        _ record: LingShuTaskExecutionRecord,
        heartbeatAge: Int,
        isStale: Bool
    ) -> String {
        if record.status.isTerminal {
            return compactActivityDiagnosticText("记录已\(record.status.rawValue)，主气泡等待收口", limit: 42)
        }

        let completed = record.plan.filter { $0.status == .completed }.count
        if let step = record.plan.first(where: { $0.status == .inProgress }) {
            return compactActivityDiagnosticText("计划 \(completed + 1)/\(max(record.plan.count, 1))：\(step.title)", limit: 48)
        }
        if let step = record.plan.first(where: { $0.status == .pending }) {
            return compactActivityDiagnosticText("下一步 \(completed + 1)/\(max(record.plan.count, 1))：\(step.title)", limit: 48)
        }

        let summary = record.threadCommit?.progressSummary ?? record.summary
        let prefix = isStale ? "超过 \(formatElapsed(heartbeatAge)) 无新心跳：" : ""
        return compactActivityDiagnosticText("\(prefix)\(summary)", limit: 52)
    }

    private func activityDiagnosticCurrentStep(_ record: LingShuTaskExecutionRecord) -> String {
        let completed = record.plan.filter { $0.status == .completed }.count
        if let step = record.plan.first(where: { $0.status == .inProgress }) {
            return compactActivityDiagnosticText("\(completed + 1)/\(max(record.plan.count, 1)) \(step.title)", limit: 32)
        }
        if let step = record.plan.first(where: { $0.status == .pending }) {
            return compactActivityDiagnosticText("待 \(completed + 1)/\(max(record.plan.count, 1)) \(step.title)", limit: 32)
        }
        return record.status.rawValue
    }

    private func activityDiagnosticWaitState(_ record: LingShuTaskExecutionRecord) -> String {
        if record.status.isTerminal { return "已结束" }
        switch record.status {
        case .queued:
            return "等待排队"
        case .waitingForUser:
            return "等待用户"
        case .acquiringCapability:
            return "等待能力"
        case .blocked, .needsRevision, .partial, .suspended, .failed:
            return record.status.rawValue
        default:
            break
        }

        if let detail = record.messages.reversed().compactMap(\.detail).first {
            switch detail {
            case .toolCall:
                return "等待工具"
            case .toolResult, .fileEdit:
                return "等待模型"
            }
        }

        if isModelExecuting || coreState == .thinking || runtimePhase != .idle {
            return "等待模型"
        }
        return "等待推进"
    }

    private func activityDiagnosticDetail(_ record: LingShuTaskExecutionRecord) -> String {
        if let structured = record.messages.reversed().compactMap({ message -> String? in
            guard let detail = message.detail else { return nil }
            switch detail {
            case let .toolCall(tool, summary, _):
                let brief = compactActivityDiagnosticText(summary, limit: 52)
                return brief.isEmpty ? "工具调用：\(Self.toolDisplayName(tool))" : "工具调用：\(Self.toolDisplayName(tool)) · \(brief)"
            case let .toolResult(tool, success, output):
                let brief = compactActivityDiagnosticText(output, limit: 52)
                let result = success ? "完成" : "失败"
                return brief.isEmpty ? "工具结果：\(Self.toolDisplayName(tool)) \(result)" : "工具结果：\(Self.toolDisplayName(tool)) \(result) · \(brief)"
            case let .fileEdit(path, operation, added, removed, _):
                let name = URL(fileURLWithPath: path).lastPathComponent
                return "文件\(operation.rawValue)：\(name) +\(added)/-\(removed)"
            }
        }).first {
            return structured
        }

        if let message = record.messages.reversed().first(where: { $0.kind != .user }) {
            let text = compactActivityDiagnosticText(message.text, limit: 64)
            if !text.isEmpty {
                return "\(message.actor) · \(text)"
            }
        }

        return compactActivityDiagnosticText(record.threadCommit?.ledgerLine ?? record.summary, limit: 64)
    }

    private func activityDiagnosticMatchedTrace(recordID: String, record: LingShuTaskExecutionRecord) -> ExecutionTraceEvent? {
        executionTrace.reversed().first {
            $0.detail.contains(recordID) || $0.detail.contains(record.title) || $0.title.contains(record.title)
        } ?? executionTrace.last
    }

    private func activityDiagnosticTrace(from matched: ExecutionTraceEvent?) -> String? {
        guard let matched else { return nil }
        let detail = compactActivityDiagnosticText(matched.detail, limit: 42)
        if detail.isEmpty {
            return "\(matched.displayTime) \(matched.actor) · \(matched.title)"
        }
        return "\(matched.displayTime) \(matched.actor) · \(matched.title)：\(detail)"
    }

    private func compactActivityDiagnosticText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return "\(normalized.prefix(max(1, limit - 1)))…"
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
                let name = Self.toolDisplayName(tool, language: language)
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

    // MARK: - 系统就绪度 / 置信度（TRUST）：真实信号合成，不再是写死的 91

    /// 真实信号：① 模型是否连通 ② 能力通道(脑/眼/耳/口)就绪比例 ③ 近期任务验收通过率（有数据才计入）。
    /// **耳/口的就绪由 `LingShuTrustScore.channelReadiness` 统一判**：本地 ASR/TTS 始终可用即就绪——
    /// 根治"ASR 写死查 `asr:datanet`、本地 ASR(默认)永不计入 → 通道恒 3/4 → 分数钉死 91%"的 bug。
    var trustSignals: (modelConnected: Bool, channelsValidated: Int, channelsTotal: Int, tasksPassed: Int, tasksFinished: Int) {
        let r = LingShuTrustScore.channelReadiness(
            brainValidated: isChannelValidated(Self.brainChannelKey(modelProvider)),
            visionValidated: isChannelValidated(Self.visionChannelKey),
            asrLocalMode: asrLocalModeEnabled,
            asrCloudValidated: isChannelValidated(Self.asrChannelKey) || isChannelValidated(Self.asrCustomKey),
            ttsLocalMode: ttsLocalModeEnabled,
            ttsActiveValidated: voiceManager.map { isChannelValidated(Self.ttsChannelKey($0.speechOutputProvider.id)) } ?? false)
        let recent = taskExecutionRecords.suffix(20)
        let terminal: [LingShuTaskExecutionStatus] = [.completed, .answered, .blocked, .needsRevision]
        let finished = recent.filter { terminal.contains($0.status) }
        let passed = finished.filter { $0.status == .completed || $0.status == .answered }.count
        return (isModelConnected, r.ready, r.total, passed, finished.count)
    }

    /// 置信度分数（0–100）：连通 0.40 / 通道就绪 0.35 / 近期验收 0.25（纯逻辑见 `LingShuTrustScore.score`）。
    var trustScore: Int {
        let s = trustSignals
        return LingShuTrustScore.score(modelConnected: s.modelConnected, channelsReady: s.channelsValidated,
                                       channelsTotal: s.channelsTotal, tasksPassed: s.tasksPassed, tasksFinished: s.tasksFinished)
    }

    /// 置信度的可解释拆解（给顶栏 / 核心区 tooltip——把"这 91% 到底怎么来的"说清楚）。
    var trustBreakdown: String {
        let s = trustSignals
        var parts = ["模型连通 " + (s.modelConnected ? "✓" : "✗"),
                     "通道校验 \(s.channelsValidated)/\(s.channelsTotal)"]
        parts.append(s.tasksFinished > 0 ? "近期验收 \(s.tasksPassed)/\(s.tasksFinished)" : "近期验收 暂无数据")
        return "系统就绪度 \(trustScore)% · " + parts.joined(separator: " · ")
    }
}
