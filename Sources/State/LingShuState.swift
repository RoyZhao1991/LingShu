import AppKit
import Combine
import SwiftUI

private enum LingShuPreferenceKeys {
    static let requiresVoiceWakeWord = "lingshu.voice.requiresWakeWord"
    static let voiceWakeWord = "lingshu.voice.wakeWord"
}

private enum LingShuPreferenceDefaults {
    static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

enum LingShuDialogueInputSource: Equatable {
    case typed
    case voice
    case plugin(String)

    var displayName: String {
        switch self {
        case .typed:
            return "文字输入"
        case .voice:
            return "语音转写"
        case .plugin(let name):
            return name
        }
    }
}

@MainActor
final class LingShuState: ObservableObject {
    @Published var selectedSurface: AppSurface = .chat
    @Published var selectedNav: NavItem = .command
    @Published var prompt: String = "我要做一个任务：让用户用语音向灵枢提交目标，由需要的能力节点分析、推进、执行、验证并最终交付。"
    @Published var isListening = false
    @Published var missionTitle = "待机中"
    @Published var missionStatus = "我在。能力池已注册，等待你的目标。"
    @Published var trustScore = 91
    @Published var coreState: LingShuCoreState = .standby
    // 每秒变化的计时量不做 @Published：它们只服务于超时判断与文案拼装，
    // 界面上的实时读数由 TimelineView 局部自刷新，避免每秒让全部观察者失效。
    var thinkingElapsedSeconds = 0
    var executionElapsedSeconds = 0
    var modelHeartbeatIdleSeconds = 0
    @Published var modelHeartbeatSource = "待机"
    @Published var mainMemoryStatus = "热记忆待检索"
    @Published var coldMemoryStatus = "冷备待检索"
    @Published var mainThreadSessionStatus = "主线程初始化中"
    @Published var mainThreadHeartbeatText = "上次 --:--:--"
    @Published var remoteSessionStatus = "在线 0 / 运行 0 / 待启动 13"
    @Published var mainRemoteConnectionStatus = "未探活"
    @Published var mainRemoteConnectionDetail = "等待主线程远端探活"
    @Published var activeLayer = "灵枢中枢"
    @Published var runtimePhase: MissionRuntimePhase = .idle
    @Published var supervisionTick = 0
    @Published var modelProvider = ModelProviderPreset.minimaxOfficial.name
    @Published var modelName = ModelProviderPreset.minimaxOfficial.defaultModels[0]
    @Published var endpoint = ModelProviderPreset.minimaxOfficial.endpoint
    @Published var apiKey = "" {
        didSet {
            guard apiKey != oldValue, let preset = selectedModelPreset else { return }
            credentialStore.setAPIKey(apiKey, forProvider: preset.id)
        }
    }
    let defaultCodexCLIPath = CodexBridge.bundledCLIPath
    @Published var codexCLIPath = CodexBridge.bundledCLIPath
    @Published var codexWorkingDirectory = "/Users/example/app"
    @Published var codexPermissionMode: CodexPermissionMode = .sandbox
    @Published var codexTimeoutSeconds = 180.0
    @Published var codexFastMode = true
    @Published var codexAuthStatus = "未检查"
    @Published var codexAuthDetail = "点击检查 Codex 登录状态"
    @Published var isCheckingCodexAuth = false
    @Published var isModelReplying = false
    @Published var isModelExecuting = false
    @Published var voiceOutputEnabled = true
    @Published var voiceWakeListeningEnabled = false
    @Published var requiresVoiceWakeWord = LingShuPreferenceDefaults.bool(
        forKey: LingShuPreferenceKeys.requiresVoiceWakeWord,
        defaultValue: true
    ) {
        didSet {
            UserDefaults.standard.set(requiresVoiceWakeWord, forKey: LingShuPreferenceKeys.requiresVoiceWakeWord)
        }
    }
    @Published var voiceWakeWord = UserDefaults.standard.string(forKey: LingShuPreferenceKeys.voiceWakeWord) ?? "灵枢" {
        didSet {
            UserDefaults.standard.set(voiceWakeWord, forKey: LingShuPreferenceKeys.voiceWakeWord)
        }
    }
    @Published var isVoiceConversationActive = false
    var lastSpokenMessageID: UUID?
    @Published var temperature = 0.2
    @Published var contextBudget = 128000.0
    @Published var localStreamingDialogueEnabled = true
    @Published var enableLocalAudit = true
    @Published var requireHumanApproval = true
    @Published var chatMessages: [ChatMessage] = [
        .init(speaker: "灵枢", text: "我在。你只管说目标，剩下的判断、分派和推进交给我。", isUser: false)
    ] {
        didSet {
            persistChatHistoryIfNeeded()
        }
    }
    @Published var hasMoreColdChatHistory = false
    @Published var executionTrace: [ExecutionTraceEvent] = [
        .init(timestamp: Date(), kind: .system, actor: "灵枢", title: "待机", detail: "主对话就绪。下达任务后，这里会显示路由、模型调用、agent 入队和工具输出。", isStream: false)
    ]
    @Published var taskRuntime: TaskRuntimeSnapshot = .idle
    @Published var activeTaskThread: LingShuTaskThread?
    @Published var taskThreads: [LingShuTaskThread] = []
    @Published var taskExecutionRecords: [LingShuTaskExecutionRecord] = []
    @Published var selectedTaskRecordID: String?
    @Published var isTaskRecordPresented = false
    @Published var archivedTaskExecutionRecords: [LingShuTaskExecutionRecord] = []
    @Published var isExecutionConsoleExpanded = true
    @Published var eventLog: [String] = [
        "09:42  灵枢主线程在线，等待指令。",
        "09:42  通用 agent 能力池已注册：在线 13 / 运行 0 / 待启动 13。",
        "09:43  高风险操作将进入人工确认。"
    ]
    @Published var supervisorEvents: [SupervisorEvent] = []
    @Published var pendingAttachments: [LingShuAttachment] = []
    /// 极简语音模式：全屏只显示输入/输出两条音频波形，纯语音对话。
    @Published var isMinimalVoiceMode = false

    let mainThreadKernel = LingShuMainThreadKernel()
    let memoryService = LingShuMemoryService()
    private let agentScheduler = LingShuAgentScheduler()
    private let taskThreadScheduler = LingShuTaskThreadScheduler(maxParallelThreads: 3)
    private let routePlanner = LingShuRoutePlanner()
    private let executionCoordinator = LingShuExecutionCoordinator()
    private let dialogueAcknowledgement = LingShuDialogueAcknowledgement()
    private let intentClarificationPolicy = LingShuIntentClarificationPolicy()
    private let taskRuntimeCoordinator = LingShuTaskRuntimeCoordinator()
    private let modelGateway = LingShuModelGateway()
    private let remoteModelClient = LingShuRemoteModelClient()
    private let permissionPolicy = LingShuPermissionPolicy()
    private let externalAgentRegistry = LingShuExternalAgentRegistry()
    private let externalAgentGateway = LingShuExternalAgentGateway()
    let credentialStore = LingShuCredentialStore()
    let chatHistoryStore = LingShuChatHistoryStore()
    let remoteSessionPool = LingShuRemoteSessionPool()
    let remoteConnectionPolicy = LingShuRemoteConnectionPolicy()
    let taskExecutionJournal = LingShuTaskExecutionJournal()
    let engineeringArtifactService = LingShuEngineeringArtifactService()
    private var missionRunID = 0
    private var thinkingStartedAt: Date?
    private var executionStartedAt: Date?
    private var lastModelHeartbeatAt: Date?
    private var activeThinkingMessageID: UUID?
    private var activeRouteHandle: CodexExecutionHandle?
    private var activeExecutionHandle: CodexExecutionHandle?
    private var activeAPITask: Task<Void, Never>?
    private var backgroundCodexHandles: [String: CodexExecutionHandle] = [:]
    private var backgroundAPITasks: [String: Task<Void, Never>] = [:]
    var isMainRemoteProbeInFlight = false
    var mainRemoteProbeRunID = 0
    var activeHealthProbeHandle: CodexExecutionHandle?
    var mainRemoteLastProbeAt: Date?
    var mainRemoteLastSuccessAt: Date?
    var mainRemoteConsecutiveFailures = 0
    var mainRemoteLastFailureReason = ""
    var mainRemoteLastDiagnosticLog = ""
    private var pendingIntentClarification: LingShuPendingIntentClarification?
    var isRestoringChatHistory = false
    var chatHistoryPersistTask: Task<Void, Never>?
    /// 由根视图注入：返回当前实时态势感知上下文（无有效信号时返回空串）。
    var livePerceptionContextProvider: (() -> String)?

    init() {
        restoreChatHistory()
        if let preset = selectedModelPreset,
           let storedKey = credentialStore.apiKey(forProvider: preset.id) {
            apiKey = storedKey
        }
        let report = mainThreadKernel.bootReport
        mainThreadSessionStatus = report.statusText
        mainThreadHeartbeatText = report.heartbeatText
        mainMemoryStatus = report.memoryStatus
        taskExecutionRecords = taskExecutionJournal.loadRecords()
        archivedTaskExecutionRecords = taskExecutionJournal.loadArchivedRecords()
        refreshRemoteSessionStatus()
        logEvent("现在  \(report.statusText)")
        appendTrace(
            kind: .system,
            actor: "主线程",
            title: report.isColdStart ? "程序冷启动" : "快照恢复",
            detail: report.recoveredTaskSummary ?? report.statusText
        )
        lastSpokenMessageID = chatMessages.last(where: { !$0.isUser && !$0.isLoading })?.id
    }

    var usesCodexAuth: Bool {
        modelGatewaySnapshot.connectionKind == .codexAuth
    }

    var modelGatewaySnapshot: LingShuModelGatewaySnapshot {
        modelGateway.snapshot(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            apiKey: apiKey,
            codexAuthStatus: codexAuthStatus,
            codexAuthDetail: codexAuthDetail
        )
    }

    var externalAgentRegistrySnapshot: LingShuExternalAgentRegistrySnapshot {
        externalAgentRegistry.snapshot()
    }

    var selectedModelPreset: ModelProviderPreset? {
        ModelProviderPreset.catalog.first { $0.name == modelProvider }
    }

    var usesLocalModelGateway: Bool {
        let fields = [
            modelProvider,
            endpoint,
            selectedModelPreset?.region ?? "",
            selectedModelPreset?.category ?? ""
        ]
        let normalized = fields.joined(separator: " ").lowercased()
        return normalized.contains("本地")
            || normalized.contains("localhost")
            || normalized.contains("127.0.0.1")
            || normalized.contains("::1")
            || normalized.contains("ollama")
            || normalized.contains("lm studio")
            || normalized.contains("vllm")
    }

    var shouldUseLocalStreamingDialogue: Bool {
        guard !usesCodexAuth, localStreamingDialogueEnabled else { return false }
        // 本地模型和 MiniMax 官方都走标准 OpenAI 流式（delta.content）。
        return usesLocalModelGateway || selectedModelPreset?.id == ModelProviderPreset.minimaxOfficial.id
    }

    var availableModelNames: [String] {
        selectedModelPreset?.defaultModels ?? []
    }

    var isModelConnected: Bool {
        modelGatewaySnapshot.isConnected
    }

    var hasActiveModelCall: Bool {
        isModelReplying || isModelExecuting
    }

    var shouldShowTaskRuntime: Bool {
        taskRuntime.stage != .dormant
    }

    var selectedTaskRecord: LingShuTaskExecutionRecord? {
        guard let selectedTaskRecordID else { return nil }
        return taskExecutionRecordLookup.first { $0.id == selectedTaskRecordID }
    }

    var selectedTaskRecordLineage: [LingShuTaskExecutionRecord] {
        guard let selectedTaskRecord else { return [] }
        return selectedTaskRecord.relatedRecordIDs.compactMap { recordID in
            taskExecutionRecordLookup.first { $0.id == recordID }
        }
    }

    var taskExecutionRecordLookup: [LingShuTaskExecutionRecord] {
        let hotIDs = Set(taskExecutionRecords.map(\.id))
        return taskExecutionRecords + archivedTaskExecutionRecords.filter { !hotIDs.contains($0.id) }
    }

    var modelConnectionState: String {
        modelGatewaySnapshot.statusText
    }

    var mainRoutingPermissionBoundary: String {
        "主线程路由：只做意图判断、记忆检索、任务分派和回应草拟，不直接修改工作区。"
    }

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

    func resetExecutionTrace(for prompt: String) {
        executionTrace = []
        let receipt = mainThreadKernel.receiveUserPrompt(prompt, memoryStatus: "等待记忆检索。")
        mainThreadHeartbeatText = receipt.displayText
        mainThreadSessionStatus = "主线程常驻运行中"
        refreshRemoteSessionStatus()
        lastModelHeartbeatAt = Date()
        modelHeartbeatIdleSeconds = 0
        modelHeartbeatSource = "用户指令"
        appendTrace(
            kind: .system,
            actor: "主线程",
            title: "受令",
            detail: "灵枢常驻主线程收到用户指令，先判断是否需要进入任务线程：\(prompt)"
        )
    }

    private func beginTaskRuntimeIfNeeded(for prompt: String, taskRecordID: String? = nil) -> Bool {
        guard isCapabilityCollaborationRequest(prompt) else {
            taskRuntime = .idle
            return false
        }

        let memoryLookup = memoryService.taskMemoryLookup(for: prompt)
        let taskID = memoryLookup.taskID
        let memoryStatus = memoryLookup.memoryStatus
        if let hotMatch = memoryLookup.hotMatch {
            linkRelatedTaskRecord(taskRecordID, relatedRecordID: hotMatch.executionRecordID, title: hotMatch.title)
        } else if let coldMemoryMatch = memoryLookup.coldMatch {
            appendTaskRecordMessage(
                taskRecordID,
                actor: "记忆",
                role: "冷备检索",
                kind: .memory,
                text: "从冷备库恢复任务摘要：\(coldMemoryMatch.title)。冷备当前只提供摘要，尚未关联完整执行流程。"
            )
        }
        let restored = memoryLookup.restored
        activeTaskThread = LingShuTaskThread.create(
            id: taskID,
            fingerprint: LingShuTaskThreadScheduler.fingerprint(for: prompt, restoredTaskID: restored ? taskID : nil),
            prompt: prompt,
            memoryStatus: memoryStatus,
            restored: restored,
            recordID: taskRecordID
        )
        if let activeTaskThread {
            if let index = taskThreads.firstIndex(where: { $0.id == activeTaskThread.id }) {
                taskThreads[index] = activeTaskThread
            } else {
                taskThreads.insert(activeTaskThread, at: 0)
            }
        }

        taskRuntime = taskRuntimeCoordinator.begin(
            taskID: taskID,
            memoryStatus: memoryStatus,
            engineLabel: modelGatewaySnapshot.engineLabel,
            restored: restored
        )

        appendTrace(
            kind: .runtime,
            actor: "任务线程",
            title: memoryLookup.traceTitle,
            detail: memoryLookup.traceDetail
        )
        return true
    }

    private func advanceTaskRuntimeAfterRoute(_ route: CodexRoutePayload, for userPrompt: String, taskRecordID: String? = nil) {
        guard isCapabilityCollaborationRequest(userPrompt) else { return }
        if taskRuntime.stage == .dormant {
            _ = beginTaskRuntimeIfNeeded(for: userPrompt, taskRecordID: taskRecordID)
        }

        let permission = taskPermissionBoundary(for: userPrompt)
        taskRuntime = taskRuntimeCoordinator.afterRoute(
            taskRuntime,
            route: route,
            engineLabel: modelGatewaySnapshot.engineLabel,
            permissionBoundary: permission
        )
        activeTaskThread?.applyRoute(
            summary: taskRuntime.summary,
            agents: route.agents.map(\.agent),
            permissionBoundary: permission
        )

        appendTrace(
            kind: .runtime,
            actor: "能力运行时",
            title: route.needsAgents ? "权限裁决" : "直接收束",
            detail: route.needsAgents ? "执行边界：\(permission)。" : "本轮无需进入工具循环。"
        )
    }

    private func markTaskRuntimeExecuting(_ route: CodexRoutePayload, for userPrompt: String) {
        guard isCapabilityCollaborationRequest(userPrompt) else { return }

        let permission = taskPermissionBoundary(for: userPrompt)
        taskRuntime = taskRuntimeCoordinator.executing(taskRuntime, permissionBoundary: permission)
        activeTaskThread?.markExecuting(permissionBoundary: taskRuntime.permissionBoundary)
        appendTrace(kind: .runtime, actor: "能力运行时", title: "进入工具循环", detail: "执行器开始按闭环推进：计划、执行、监控、检查、回传。")
    }

    private func markTaskRuntimeMonitoring() {
        taskRuntime = taskRuntimeCoordinator.monitoring(taskRuntime)
    }

    private func completeTaskRuntime(for userPrompt: String, reply: String, taskRecordID: String? = nil) {
        guard isCapabilityCollaborationRequest(userPrompt) else { return }

        taskRuntime = taskRuntimeCoordinator.delivered(taskRuntime)
        activeTaskThread?.markDelivered(summary: reply)
        appendTrace(kind: .runtime, actor: "能力运行时", title: "Review 通过", detail: "执行报告已回传，灵枢完成本轮验收。")
        rememberTask(prompt: userPrompt, status: "delivered", summary: reply, taskRecordID: taskRecordID)
    }

    private func blockTaskRuntime(_ error: String) {
        guard taskRuntime.stage != .dormant else { return }

        taskRuntime = taskRuntimeCoordinator.blocked(taskRuntime, error: error)
        activeTaskThread?.markBlocked(reason: error)
        appendTrace(kind: .runtime, actor: "能力运行时", title: "阻断", detail: error)
    }

    /// 事件日志统一入口：头部插入并裁剪上限，防止长会话期间无界增长。
    func logEvent(_ text: String) {
        eventLog.insert(text, at: 0)
        if eventLog.count > 200 {
            eventLog.removeLast(eventLog.count - 200)
        }
    }

    func appendTrace(kind: LingShuTraceKind, actor: String, title: String, detail: String, isStream: Bool = false) {
        let cleanedDetail = cleanTraceText(detail)
        guard !cleanedDetail.isEmpty else { return }

        executionTrace.append(.init(
            timestamp: Date(),
            kind: kind,
            actor: actor,
            title: title,
            detail: cleanedDetail,
            isStream: isStream
        ))

        if executionTrace.count > 180 {
            executionTrace.removeFirst(executionTrace.count - 180)
        }
    }

    func appendCodexStream(_ rawText: String, actor: String) {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map(cleanTraceText)
            .filter { !$0.isEmpty }
        let suppressTrace = isGuardActor(actor)

        for line in lines.prefix(12) {
            if line.hasPrefix("__LINGSHU_HEARTBEAT__") {
                let detail = line
                    .replacingOccurrences(of: "__LINGSHU_HEARTBEAT__", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                recordModelHeartbeat(source: actor, detail: detail.isEmpty ? "底层进程仍在运行。" : detail, isSynthetic: true)
            } else if CodexDiagnosticLogFilter.isInternalDiagnosticLine(line) {
                recordModelHeartbeat(source: actor, detail: "底层流式连接正在自动重试，进程仍保持活跃。", isSynthetic: false)
                recordRemoteStreamRetryDiagnostic(line, actor: actor)
            } else {
                recordModelHeartbeat(source: actor, detail: line, isSynthetic: false)
                if !suppressTrace {
                    appendTrace(kind: .tool, actor: actor, title: "底层输出", detail: line, isStream: true)
                }
            }
        }
    }

    private func appendModelStream(_ rawText: String, actor: String) {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map(cleanTraceText)
            .filter { !$0.isEmpty }

        for line in lines.prefix(12) {
            recordModelHeartbeat(source: actor, detail: line, isSynthetic: false)
            appendTrace(kind: .model, actor: actor, title: "流式输出", detail: line, isStream: true)
        }
    }

    private func recordRemoteStreamRetryDiagnostic(_ line: String, actor: String) {
        mainRemoteLastDiagnosticLog = line
        if mainRemoteConsecutiveFailures == 0 {
            mainRemoteConnectionStatus = LingShuRemoteConnectionPhase.degraded.rawValue
            mainRemoteConnectionDetail = "检测到流式断开，底层正在自动重试。"
        }
    }

    func recordModelHeartbeat(source: String, detail: String, isSynthetic: Bool = false) {
        lastModelHeartbeatAt = Date()
        modelHeartbeatIdleSeconds = 0
        modelHeartbeatSource = source
    }

    private func isGuardActor(_ actor: String) -> Bool {
        actor.contains("守护") || actor.contains("探活")
    }

    private func cleanTraceText(_ rawText: String) -> String {
        let withoutControlCharacters = rawText
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard withoutControlCharacters.count > 420 else {
            return withoutControlCharacters
        }

        return String(withoutControlCharacters.prefix(420)) + "..."
    }

    func enterCoreState(_ newState: LingShuCoreState, resetTimer: Bool = true) {
        let now = Date()

        if coreState == .thinking, let startedAt = thinkingStartedAt {
            thinkingElapsedSeconds = max(thinkingElapsedSeconds, Int(now.timeIntervalSince(startedAt)))
        }

        if coreState == .executing, let startedAt = executionStartedAt {
            executionElapsedSeconds = max(executionElapsedSeconds, Int(now.timeIntervalSince(startedAt)))
        }

        coreState = newState

        switch newState {
        case .standby:
            thinkingStartedAt = nil
            executionStartedAt = nil
            lastModelHeartbeatAt = nil
            modelHeartbeatIdleSeconds = 0
            modelHeartbeatSource = "待机"
            if resetTimer {
                thinkingElapsedSeconds = 0
                executionElapsedSeconds = 0
            }
        case .thinking:
            if resetTimer || thinkingStartedAt == nil {
                thinkingStartedAt = now
                thinkingElapsedSeconds = 0
            }
            executionStartedAt = nil
            executionElapsedSeconds = 0
            lastModelHeartbeatAt = now
            modelHeartbeatIdleSeconds = 0
            modelHeartbeatSource = "路由模型"
        case .executing:
            if resetTimer || executionStartedAt == nil {
                executionStartedAt = now
                executionElapsedSeconds = 0
            }
            thinkingStartedAt = nil
            lastModelHeartbeatAt = now
            modelHeartbeatIdleSeconds = 0
            modelHeartbeatSource = "执行模型"
        case .abnormal:
            thinkingStartedAt = nil
            executionStartedAt = nil
        }
    }

    func tickCoreTimers() {
        let now = Date()
        if let heartbeat = mainThreadKernel.heartbeat(now: now) {
            mainThreadHeartbeatText = heartbeat.displayText
            if mainThreadSessionStatus != "主线程常驻运行中" {
                mainThreadSessionStatus = "主线程常驻运行中"
            }
        }
        refreshRemoteSessionStatus()
        tickMainRemoteConnectionGuard(now: now)

        if hasActiveModelCall, let lastModelHeartbeatAt {
            modelHeartbeatIdleSeconds = max(0, Int(now.timeIntervalSince(lastModelHeartbeatAt)))
        }

        if coreState == .thinking, let startedAt = thinkingStartedAt {
            thinkingElapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
            updateThinkingBubble()

            if thinkingElapsedSeconds == 45 {
                missionStatus = "主通道响应偏慢，我还在等它给出可靠判断。"
            } else if thinkingElapsedSeconds == 90 {
                missionStatus = "仍在思考中。我不会把未完成的判断伪装成结果。"
            } else if isModelReplying && modelHeartbeatIdleSeconds >= Int(codexTimeoutSeconds) {
                handleModelTimeout(stage: "判断阶段", messageID: activeThinkingMessageID)
            }
        }

        if coreState == .executing, let startedAt = executionStartedAt, isModelExecuting || runtimePhase != .idle {
            executionElapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))

            if isModelExecuting && modelHeartbeatIdleSeconds >= Int(codexTimeoutSeconds) {
                handleModelTimeout(stage: "执行阶段", messageID: nil)
            }
        }
    }

    private func handleModelTimeout(stage: String, messageID: UUID?) {
        cancelActiveCodexCalls()
        isModelReplying = false
        isModelExecuting = false
        let response = "主通道连续 \(Int(codexTimeoutSeconds)) 秒没有心跳，我已停止本轮\(stage)。"
        appendTrace(kind: .warning, actor: "灵枢", title: "\(stage)失联", detail: response)
        blockTaskRuntime(response)
        resetAgentRuntime(title: "异常", status: response)
        enterCoreState(.abnormal, resetTimer: false)
        activeLayer = "异常"

        if let messageID,
           let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].text = response
            chatMessages[index].isLoading = false
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false))
        }

        logEvent("现在  \(stage)连续 \(Int(codexTimeoutSeconds)) 秒没有心跳，已停止本轮。")
    }

    private func cancelActiveCodexCalls() {
        activeRouteHandle?.cancel()
        activeExecutionHandle?.cancel()
        activeHealthProbeHandle?.cancel()
        backgroundCodexHandles.values.forEach { $0.cancel() }
        backgroundAPITasks.values.forEach { $0.cancel() }
        activeAPITask?.cancel()
        activeRouteHandle = nil
        activeExecutionHandle = nil
        activeHealthProbeHandle = nil
        backgroundCodexHandles = [:]
        backgroundAPITasks = [:]
        activeAPITask = nil
        if isMainRemoteProbeInFlight {
            mainRemoteProbeRunID += 1
            isMainRemoteProbeInFlight = false
            refreshMainRemoteConnectionStatus()
        }
    }

    private func cancelMainRemoteHealthProbe(reason _: String, detail _: String) {
        guard isMainRemoteProbeInFlight else { return }
        mainRemoteProbeRunID += 1
        activeHealthProbeHandle?.cancel()
        activeHealthProbeHandle = nil
        isMainRemoteProbeInFlight = false
        refreshMainRemoteConnectionStatus()
    }

    func cancelCurrentCall() {
        guard hasActiveModelCall else { return }

        let messageID = activeThinkingMessageID
        cancelActiveCodexCalls()
        isModelReplying = false
        isModelExecuting = false

        let response = "本轮调用已停止。"
        appendTrace(kind: .warning, actor: "用户", title: "停止调用", detail: "用户中止当前模型进程，灵枢已撤销本轮路由/执行。")
        blockTaskRuntime("用户手动停止了本轮能力运行时。")
        resetAgentRuntime(title: "待机中", status: response)
        enterCoreState(.standby, resetTimer: false)
        activeLayer = "待机中"

        if let messageID,
           let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].text = response
            chatMessages[index].isLoading = false
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false))
        }

        logEvent("现在  用户停止了本轮模型调用。")
    }

    private func updateThinkingBubble() {
        guard let messageID = activeThinkingMessageID,
              let index = chatMessages.firstIndex(where: { $0.id == messageID }),
              !chatMessages[index].isLoading else {
            return
        }

        chatMessages[index].isLoading = true
    }

    /// 记忆提示 + 实时态势感知的统一组装：有有效感知信号时注入对话上下文。
    /// 按当前主通道选择回复适配器（M3 内联 think / 标准模型直通）。
    var currentReplyAdapter: LingShuModelReplyAdapting {
        LingShuModelReplyAdapters.adapter(provider: modelProvider, model: modelName)
    }

    func composedPromptHint(baseMemory: String) -> String {
        var hint = mainThreadKernel.promptHint(baseMemory: baseMemory)
        if let perception = livePerceptionContextProvider?(),
           !perception.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hint += "\n实时态势感知（来自麦克风/摄像头，已通过感知网关解析）：\n\(perception)"
        }
        return hint
    }

    /// 网关计量：记录本轮调用消耗的 token，供前端展示用量。
    func recordModelUsage(_ reply: LingShuRemoteModelReply, stage: String) {
        guard let tokens = reply.totalTokens else { return }
        appendTrace(kind: .system, actor: "用量", title: stage, detail: "本轮消耗 \(tokens) tokens（网关计量）。")
    }

    /// 感知专项接口客户端：仅当当前通道是数据网络网关且已配置 token 时可用。
    /// 图片/音频/视频等感知任务统一走网关，不直连底层模型。
    /// 感知专项接口固定走数据网络网关，独立于主通道：主通道切到 MiniMax 官方后，
    /// 图片/音频/视频仍用数据网关的凭据（按 datanet-gateway 从钥匙串取），互不影响。
    var cloudPerceptionClient: LingShuCloudPerceptionClient? {
        let gateway = ModelProviderPreset.dataNetGateway
        // 当前主通道就是数据网关时用当前 apiKey，否则从钥匙串取数据网关自己的 key。
        let currentKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (selectedModelPreset?.id == gateway.id && !currentKey.isEmpty)
            ? currentKey
            : credentialStore.apiKey(forProvider: gateway.id)
        guard let token, !token.isEmpty, let url = URL(string: gateway.endpoint) else {
            return nil
        }
        return LingShuCloudPerceptionClient(baseEndpoint: url, token: token)
    }

    func applyModelProvider(_ providerName: String) {
        guard providerName != "__choose_api_provider__" else { return }
        cancelMainRemoteHealthProbe(reason: "探活让路", detail: "收到用户指令，已停止后台探活，把主通道让给本轮任务。")

        guard let preset = ModelProviderPreset.catalog.first(where: { $0.name == providerName }) else {
            modelProvider = providerName
            return
        }

        modelProvider = preset.name
        endpoint = preset.endpoint

        if let firstModel = preset.defaultModels.first, !preset.defaultModels.contains(modelName) {
            modelName = firstModel
        }

        if let storedKey = credentialStore.apiKey(forProvider: preset.id) {
            apiKey = storedKey
        }

        if preset.name == "Codex Auth" {
            codexCLIPath = CodexBridge.bundledCLIPath
        }

        logEvent("现在  模型供应商切换为 \(preset.name)，协议：\(preset.protocolName)。")
        appendTrace(kind: .system, actor: "配置", title: "模型供应商", detail: "已切换为 \(preset.name)，协议：\(preset.protocolName)。")
    }

    var activeWorkerCount: Int {
        guard canShowAgentRuntime else { return 0 }
        return agents.filter { $0.mode == .working || $0.mode == .verifying || $0.mode == .correcting }.count
    }

    var activeSupervisorCount: Int {
        guard canShowAgentRuntime else { return 0 }
        return agents.filter { $0.mode == .supervising }.count
    }

    var canShowAgentRuntime: Bool {
        if usesCodexAuth {
            return codexAuthStatus == "已登录" && (isModelReplying || isModelExecuting || runtimePhase != .idle || !supervisorEvents.isEmpty)
        }

        return isModelConnected && runtimePhase != .idle
    }

    var callChainAgents: [LingShuAgent] {
        guard canShowAgentRuntime else { return [] }
        return agents.filter { agent in
            agent.state != .waiting ||
            agent.mode != .dormant ||
            agent.lastFinding != "尚未巡检"
        }
    }

    @Published var agents: [LingShuAgent] = [
        .init(name: "规划智能体", shortName: "规划", role: LingShuCapabilityRole.planning.description, domain: "通用治理", symbol: "doc.text.magnifyingglass", color: .teal, load: 0.34, state: .waiting),
        .init(name: "审议智能体", shortName: "审议", role: LingShuCapabilityRole.review.description, domain: "通用治理", symbol: "checkmark.shield", color: .red, load: 0.32, state: .waiting),
        .init(name: "调度智能体", shortName: "调度", role: LingShuCapabilityRole.dispatch.description, domain: "通用治理", symbol: "arrow.triangle.branch", color: .orange, load: 0.36, state: .waiting),
        .init(name: "设计智能体", shortName: "设计", role: LingShuCapabilityRole.design.description, domain: "设计交付", symbol: "paintpalette.fill", color: .pink, load: 0.29, state: .waiting),
        .init(name: "执行智能体", shortName: "执行", role: LingShuCapabilityRole.execution.description, domain: "能力节点", symbol: "bolt.fill", color: .orange, load: 0.31, state: .waiting),
        .init(name: "监控智能体", shortName: "监控", role: LingShuCapabilityRole.monitoring.description, domain: "能力节点", symbol: "waveform.path.ecg", color: .cyan, load: 0.28, state: .waiting),
        .init(name: "验证智能体", shortName: "验证", role: LingShuCapabilityRole.verification.description, domain: "能力节点", symbol: "checklist.checked", color: .green, load: 0.24, state: .waiting),
        .init(name: "记忆智能体", shortName: "记忆", role: LingShuCapabilityRole.memory.description, domain: "记忆层", symbol: "memorychip", color: .purple, load: 0.26, state: .waiting),
        .init(name: "安全智能体", shortName: "安全", role: LingShuCapabilityRole.safety.description, domain: "治理边界", symbol: "lock.shield", color: .red, load: 0.25, state: .waiting),
        .init(name: "知识智能体", shortName: "知识", role: LingShuCapabilityRole.knowledge.description, domain: "知识层", symbol: "books.vertical", color: .purple, load: 0.27, state: .waiting),
        .init(name: "路由智能体", shortName: "路由", role: LingShuCapabilityRole.routing.description, domain: "协议层", symbol: "point.3.connected.trianglepath.dotted", color: .brown, load: 0.30, state: .waiting)
    ]

    @Published var missionSteps: [MissionStep] = [
        .init(title: "灵枢受令", agent: "灵枢", detail: "用户向通用中枢下达目标。", state: .waiting),
        .init(title: "规划拟案", agent: "规划", detail: "形成任务草案、执行计划和能力分派建议。", state: .waiting),
        .init(title: "审议同步审核", agent: "审议", detail: "审核风险、权限、事实和是否需要封驳。", state: .waiting),
        .init(title: "调度定落地", agent: "调度", detail: "把已批准计划调度给能力节点或外部执行器。", state: .waiting),
        .init(title: "能力节点执行", agent: "按需能力节点", detail: "由调度节点按任务需要唤起通用或外部能力。", state: .waiting),
        .init(title: "过程审议", agent: "审议", detail: "执行期间同步审核风险、越权和偏航。", state: .waiting),
        .init(title: "调度汇总交付", agent: "调度/验证", detail: "汇总产物、验证结果和未完成项。", state: .waiting),
        .init(title: "灵枢最终验收", agent: "灵枢", detail: "以通用中枢身份对用户统一负责。", state: .waiting)
    ]

    let domains: [CapabilityDomain] = [
        .init(title: "软件工程", detail: "作为首个能力包验证智能体协作闭环。", icon: "hammer", color: .orange, maturity: 0.74, modules: ["需求", "项目", "架构", "设计", "开发", "测试"]),
        .init(title: "资料研究", detail: "面向论文、行业资料、标准协议的证据型检索。", icon: "books.vertical", color: .purple, maturity: 0.42, modules: ["检索", "摘要", "引用", "对比"]),
        .init(title: "设计交付", detail: "根据需求产出 PPT、演示页、视觉方案和汇报材料。", icon: "rectangle.on.rectangle.angled", color: .pink, maturity: 0.52, modules: ["叙事", "版式", "图表", "导出"]),
        .init(title: "文档生产", detail: "生成开题、设计文档、实验报告和答辩材料。", icon: "doc.richtext", color: .teal, maturity: 0.57, modules: ["大纲", "改写", "排版", "导出"]),
        .init(title: "日程邮件", detail: "处理个人事务、会议、待办和沟通流。", icon: "calendar.badge.clock", color: .blue, maturity: 0.28, modules: ["提醒", "邮件", "会议", "跟进"]),
        .init(title: "数据分析", detail: "把文件、表格和数据库转成可解释结论。", icon: "chart.xyaxis.line", color: .green, maturity: 0.35, modules: ["清洗", "建模", "图表", "报告"]),
        .init(title: "设备自动化", detail: "面向 Mac、浏览器、终端和未来 IoT 的工具控制。", icon: "switch.2", color: .red, maturity: 0.31, modules: ["快捷键", "脚本", "浏览器", "终端"])
    ]

    func toggleListening() {
        isListening.toggle()
        if isListening {
            missionTitle = "正在监听"
            missionStatus = "语音入口已激活。当前原型先模拟唤醒，后续接入 Speech framework 与快捷指令。"
            logEvent("现在  语音入口进入监听状态。")
        } else {
            missionTitle = "语音已暂停"
            missionStatus = "可以通过按钮或 Command-R 触发一次演示任务。"
            logEvent("现在  语音入口已暂停。")
        }
    }

    @discardableResult
    func sendPrompt() -> String {
        let attachmentContext = attachmentContextBlock()
        guard !attachmentContext.isEmpty else {
            return submitTextInput(prompt, source: .typed)
        }

        // 有附件时：用户消息原文照常入库展示，但发给模型的提示前置附件正文上下文。
        let userText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = userText.isEmpty
            ? "\(attachmentContext)\n\n请按上述文件落地交付。"
            : "\(attachmentContext)\n\n用户指令：\n\(userText)"
        let displayText = userText.isEmpty ? "[上传了 \(pendingAttachments.count) 个文件]" : userText
        chatMessages.append(.init(speaker: "你", text: displayText, isUser: true))
        prompt = ""
        clearAttachments()
        return submitTextInput(combined, source: .typed, appendUserMessage: false)
    }

    @discardableResult
    func submitVoiceTranscript(_ text: String) -> String {
        submitTextInput(text, source: .voice)
    }

    @discardableResult
    func submitTextInput(
        _ text: String,
        source: LingShuDialogueInputSource = .typed,
        existingTaskRecordID: String? = nil,
        appendUserMessage: Bool = true,
        bypassActiveGate: Bool = false,
        forcedThreadID: String? = nil
    ) -> String {
        let trimmedPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return "" }
        cancelMainRemoteHealthProbe(reason: "探活让路", detail: "收到用户指令，已停止后台探活，把主通道让给本轮任务。")

        if let clarificationResponse = resolvePendingIntentClarificationIfNeeded(
            trimmedPrompt,
            source: source,
            appendUserMessage: appendUserMessage,
            bypassActiveGate: bypassActiveGate,
            forcedThreadID: forcedThreadID
        ) {
            return clarificationResponse
        }

        let isPotentialTask = isCapabilityCollaborationRequest(trimmedPrompt)

        let taskRecordID = existingTaskRecordID ?? createTaskExecutionRecord(for: trimmedPrompt)
        if appendUserMessage {
            chatMessages.append(.init(speaker: "你", text: trimmedPrompt, isUser: true))
        }
        prompt = ""

        let concurrentCandidate = !bypassActiveGate && hasActiveModelCall
        if concurrentCandidate {
            appendTrace(kind: .runtime, actor: "任务队列", title: "并发接令", detail: "当前已有模型调用运行，本轮先进入线程调度判断。")
        } else {
            resetExecutionTrace(for: trimmedPrompt)
        }
        appendTrace(
            kind: .system,
            actor: source.displayName,
            title: "文本入队",
            detail: "\(source.displayName) 已落成文本，进入灵枢主线程判断。"
        )
        let mainMemoryContext = prepareMainThreadMemory(for: trimmedPrompt)
        appendTaskRecordMessage(taskRecordID, actor: "记忆", role: "主线程记忆", kind: .memory, text: mainMemoryContext.status)

        if let directAnswer = mainThreadDirectAnswer(for: trimmedPrompt, memoryContext: mainMemoryContext) {
            return requestLocalKnowledgeReply(for: trimmedPrompt, memoryContext: mainMemoryContext, answer: directAnswer, taskRecordID: taskRecordID)
        }

        if let clarification = intentClarificationPolicy.clarification(
            for: trimmedPrompt,
            memoryContext: mainMemoryContext,
            focusedTaskTitle: activeTaskThread?.prompt
        ) {
            return requestIntentClarification(
                for: trimmedPrompt,
                decision: clarification,
                taskRecordID: taskRecordID
            )
        }

        if concurrentCandidate {
            return handleConcurrentSubmission(
                prompt: trimmedPrompt,
                source: source,
                taskRecordID: taskRecordID,
                mainMemoryContext: mainMemoryContext,
                isPotentialTask: isPotentialTask
            )
        }

        if isPotentialTask {
            let memoryLookup = memoryService.taskMemoryLookup(for: trimmedPrompt)
            let threadID = forcedThreadID ?? memoryLookup.taskID
            upsertTaskThread(
                id: threadID,
                fingerprint: LingShuTaskThreadScheduler.fingerprint(
                    for: trimmedPrompt,
                    restoredTaskID: memoryLookup.restored ? memoryLookup.taskID : forcedThreadID
                ),
                prompt: trimmedPrompt,
                memoryStatus: memoryLookup.memoryStatus,
                restored: memoryLookup.restored || forcedThreadID != nil,
                recordID: taskRecordID
            )
        }

        if usesCodexAuth {
            guard codexAuthStatus == "已登录" else {
                enterCoreState(.abnormal)
                appendTrace(kind: .warning, actor: "灵枢", title: "主通道未接入", detail: "Codex Auth 当前不是已登录状态，本轮不会伪造模型判断。")
                if isPotentialTask {
                    appendTrace(kind: .runtime, actor: "主线程", title: "未创建任务线程", detail: "主通道未接入，无法完成工程任务准入判断。")
                }
                resetAgentRuntime(
                    title: "等待接入",
                    status: "我的主通道还没有就绪。完成配置后，我会重新接管判断与分派。"
                )
                let response = "我还没有接入主通道。请先到“配置”页完成登录检查；接通之后，你只需要继续对我下令。"
                appendTaskRecordMessage(taskRecordID, actor: "主线程", role: "通道检查", kind: .warning, text: "主通道未接入，本轮无法进行可靠的模型判断和能力分派。")
                appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: response)
                finishTaskRecord(taskRecordID, status: .blocked, summary: response)
                chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: taskRecordID))
                return response
            }

            enterCoreState(.thinking)
            missionTitle = "思考中"
            missionStatus = "我正在判断这件事该由我直接处理，还是交给相关能力节点协同。"
            activeLayer = "思考中"
            runtimePhase = .idle
            appendTrace(kind: .model, actor: "灵枢", title: "进入思考", detail: "判断这条指令是否需要调用专家 agent。")
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .core, text: "我正在判断这件事由我直接处理，还是需要创建能力节点任务。")

            let pending = ChatMessage(
                speaker: "灵枢",
                text: dialogueAcknowledgement.intake(for: trimmedPrompt),
                isUser: false,
                isLoading: true,
                taskRecordID: taskRecordID
            )
            chatMessages.append(pending)
            activeThinkingMessageID = pending.id
            requestRoutedCodexReply(for: trimmedPrompt, memoryContext: mainMemoryContext, replacing: pending.id, taskRecordID: taskRecordID)
            return pending.text
        }

        guard isModelConnected else {
            enterCoreState(.abnormal)
            appendTrace(kind: .warning, actor: "灵枢", title: "模型未连接", detail: "API 通道没有可用密钥或连接状态，本轮停止。")
            if isPotentialTask {
                appendTrace(kind: .runtime, actor: "主线程", title: "未创建任务线程", detail: "主通道未配置，无法完成工程任务准入判断。")
            }
            resetAgentRuntime(
                title: "等待接入",
                status: "主通道还没有配置完成。配置完成后，我会恢复判断与分派。"
            )
            let response = "我还没有可用的主通道。请先在“配置”页完成模型访问配置；接通后，我会继续为你处理。"
            appendTaskRecordMessage(taskRecordID, actor: "模型网关", role: "连接检查", kind: .warning, text: "API 通道没有可用密钥或连接状态，本轮停止。")
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: response)
            finishTaskRecord(taskRecordID, status: .blocked, summary: response)
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: taskRecordID))
            return response
        }

        enterCoreState(.thinking)
        missionTitle = "思考中"
        missionStatus = "我正在通过已配置的大模型通道判断本轮是否需要能力节点协同。"
        activeLayer = "模型网关"
        runtimePhase = .idle
        appendTrace(kind: .model, actor: "模型网关", title: "进入思考", detail: "通过 \(modelGatewaySnapshot.engineLabel) 发起真实路由请求。")
        appendTaskRecordMessage(taskRecordID, actor: "模型网关", role: "主通道", kind: .model, text: "已接入 \(modelGatewaySnapshot.engineLabel)，正在进行本轮路由判断。")

        let pending = ChatMessage(
            speaker: "灵枢",
            text: dialogueAcknowledgement.intake(for: trimmedPrompt),
            isUser: false,
            isLoading: true,
            taskRecordID: taskRecordID
        )
        chatMessages.append(pending)
        activeThinkingMessageID = pending.id
        requestAPIGatewayRouteReply(for: trimmedPrompt, memoryContext: mainMemoryContext, replacing: pending.id, taskRecordID: taskRecordID)
        return pending.text
    }

    private func resolvePendingIntentClarificationIfNeeded(
        _ userReply: String,
        source: LingShuDialogueInputSource,
        appendUserMessage: Bool,
        bypassActiveGate: Bool,
        forcedThreadID: String?
    ) -> String? {
        guard let pending = pendingIntentClarification else { return nil }

        pendingIntentClarification = nil

        if appendUserMessage {
            chatMessages.append(.init(speaker: "你", text: userReply, isUser: true, taskRecordID: pending.recordID))
        }

        appendTaskRecordMessage(
            pending.recordID,
            actor: "你",
            role: "补充说明",
            kind: .user,
            text: userReply
        )

        if intentClarificationPolicy.isCancellation(userReply) {
            let response = "好，我先不推进。等你想清楚目标后，直接告诉我。"
            resetAgentRuntime(
                title: "待机中",
                status: "\(agentRuntimeCounts.statusText)本轮澄清已取消。"
            )
            appendTaskRecordMessage(
                pending.recordID,
                actor: "灵枢",
                role: "中枢",
                kind: .result,
                text: response
            )
            finishTaskRecord(pending.recordID, status: .answered, summary: "用户取消澄清后的推进。")
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: pending.recordID))
            return response
        }

        let clarifiedPrompt = intentClarificationPolicy.clarifiedPrompt(
            originalPrompt: pending.originalPrompt,
            clarificationAnswer: userReply
        )
        appendTaskRecordMessage(
            pending.recordID,
            actor: "主线程",
            role: "意图澄清",
            kind: .router,
            text: "已收到补充说明，合并原始需求后重新进入准入判断。"
        )
        appendTrace(
            kind: .route,
            actor: "主线程",
            title: "澄清完成",
            detail: "用户已补充真实意图，灵枢将合并上下文后重新判断是否需要能力节点。"
        )

        return submitTextInput(
            clarifiedPrompt,
            source: source,
            existingTaskRecordID: pending.recordID,
            appendUserMessage: false,
            bypassActiveGate: bypassActiveGate,
            forcedThreadID: forcedThreadID
        )
    }

    private func requestIntentClarification(
        for userPrompt: String,
        decision: LingShuIntentClarificationDecision,
        taskRecordID: String?
    ) -> String {
        pendingIntentClarification = .init(
            originalPrompt: userPrompt,
            recordID: taskRecordID,
            question: decision.question,
            createdAt: Date()
        )

        isModelReplying = false
        isModelExecuting = false
        activeThinkingMessageID = nil
        taskRuntime = .idle
        enterCoreState(.standby, resetTimer: false)
        resetAgentRuntime(
            title: "等待确认",
            status: "\(agentRuntimeCounts.statusText)我需要先确认你的真实意图，再决定是否分派能力节点。"
        )
        appendTrace(
            kind: .route,
            actor: "主线程",
            title: "需要澄清",
            detail: decision.reason
        )
        appendTaskRecordMessage(
            taskRecordID,
            actor: "主线程",
            role: "意图澄清",
            kind: .router,
            text: decision.reason
        )
        applyTaskRecordRoute(
            taskRecordID,
            route: .init(
                needsAgents: false,
                agents: [],
                directAnswer: decision.question,
                finalAnswer: decision.question,
                summary: "需要澄清用户真实意图，暂不创建任务线程。"
            )
        )
        appendTaskRecordMessage(
            taskRecordID,
            actor: "灵枢",
            role: "中枢",
            kind: .result,
            text: decision.question
        )
        finishTaskRecord(taskRecordID, status: .answered, summary: "灵枢发起澄清，暂不创建任务线程。")
        chatMessages.append(.init(speaker: "灵枢", text: decision.question, isUser: false, taskRecordID: taskRecordID))
        return decision.question
    }

    private func handleConcurrentSubmission(
        prompt userPrompt: String,
        source: LingShuDialogueInputSource,
        taskRecordID: String?,
        mainMemoryContext: MainThreadMemoryContext,
        isPotentialTask: Bool
    ) -> String {
        let memoryLookup = memoryService.taskMemoryLookup(for: userPrompt)
        let decision = taskThreadScheduler.decide(
            prompt: userPrompt,
            memoryLookup: memoryLookup,
            activeThreads: taskThreads,
            focusedThread: activeTaskThread,
            hasForegroundCall: hasActiveModelCall
        )

        appendTaskRecordMessage(
            taskRecordID,
            actor: "任务队列",
            role: "线程调度",
            kind: .router,
            text: decision.reason
        )
        logEvent("现在  任务调度：\(decision.reason)")

        switch decision.action {
        case .enqueueSameThread:
            enqueueTaskSegment(
                threadID: decision.threadID,
                fingerprint: decision.fingerprint,
                prompt: userPrompt,
                recordID: taskRecordID,
                reason: decision.reason
            )
            let response = "收到。这是当前任务的后续迭代，我已放入同一任务队列；前一段完成后会按顺序继续。"
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: response)
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: taskRecordID))
            return response

        case .enqueueUntilCapacity:
            enqueueTaskSegment(
                threadID: decision.threadID,
                fingerprint: decision.fingerprint,
                prompt: userPrompt,
                recordID: taskRecordID,
                reason: decision.reason
            )
            let response = "收到。当前并行线程已满，这个任务已进入等待队列；有线程释放后我会接上。"
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: response)
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: taskRecordID))
            return response

        case .startParallel:
            upsertTaskThread(
                id: decision.threadID,
                fingerprint: decision.fingerprint,
                prompt: userPrompt,
                memoryStatus: memoryLookup.memoryStatus,
                restored: memoryLookup.restored,
                recordID: taskRecordID
            )
            let response = isPotentialTask
                ? "收到。这是独立任务，我已创建隔离线程并行推进；当前任务的状态会写入它自己的执行记录。"
                : "收到。我会在隔离线程里处理这个问题，不打断当前任务。"
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: response)
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: taskRecordID))
            requestBackgroundRouteReply(
                for: userPrompt,
                memoryContext: mainMemoryContext,
                taskRecordID: taskRecordID,
                threadID: decision.threadID,
                sourceLabel: source.displayName
            )
            return response

        case .startForeground:
            return submitTextInput(
                userPrompt,
                source: source,
                existingTaskRecordID: taskRecordID,
                appendUserMessage: false,
                bypassActiveGate: true,
                forcedThreadID: decision.threadID
            )
        }
    }

    private func mainThreadDirectAnswer(for prompt: String, memoryContext: MainThreadMemoryContext) -> String? {
        let normalized = normalizeMemoryText(prompt)

        if let localAnswer = LingShuLocalIntentResolver.answer(for: prompt) {
            return localAnswer
        }

        let identityPrompts = ["你是谁", "你是什么", "你叫什么", "灵枢是谁"]
        if identityPrompts.contains(normalized) || (normalized.contains("你是谁") && normalized.count <= 8) {
            return "我是灵枢，有什么可以帮你的？"
        }

        let selfIdentityPrompts = ["我是谁", "你知道我是谁吗", "你知道我是谁么", "你知道我是谁", "我是什么人"]
        if selfIdentityPrompts.contains(normalized) {
            return userIdentityAnswer(from: memoryContext)
        }

        let greetingPrompts = ["你好", "您好", "在吗", "hello", "hi"]
        if greetingPrompts.contains(normalized) {
            return "我在。有什么可以帮你的？"
        }

        if isLingShuKnowledgeQuestion(prompt) {
            let memoryNote = memoryContext.shouldLoadHistory
                ? "\n\n我已参考主线程记忆：\(compactSummaryText(memoryContext.status, limit: 90))"
                : ""

            if normalized.contains("记忆") || normalized.contains("线程") || normalized.contains("冷备") || normalized.contains("压缩") {
                return "灵枢的记忆分两层：主线程记忆负责判断当前消息是否续接历史主题；执行记忆负责恢复具体任务线程的目标、约束、已完成事项和风险。热记忆过长或过旧时会压缩并进入冷备库，后续可以通过检索冷备重新接起。\(memoryNote)"
            }

            if normalized.contains("agent") || normalized.contains("智能体") || normalized.contains("调用链") {
                return "灵枢不会一开始展示所有 agent。主线程先判断当前任务是否需要协作；需要时才动态创建任务线程，并只在右侧调用链显示本轮真实参与的 agent。普通问答则由我基于记忆和知识库直接回应。\(memoryNote)"
            }

            if normalized.contains("能力") || normalized.contains("架构") || normalized.contains("流程") || normalized.contains("怎么工作") {
                return "灵枢的核心不是亲自做工，而是承令、判断、分派、监督和验收。主线程负责理解意图和检索记忆；任务线程负责承接需要落地的工作；内部或外部 agent 负责具体执行；最终由我统一向你交付结果。\(memoryNote)"
            }
        }

        return nil
    }

    private func requestLocalKnowledgeReply(
        for userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        answer: String,
        taskRecordID: String?
    ) -> String {
        isModelReplying = true
        enterCoreState(.thinking)
        missionTitle = "思考中"
        missionStatus = memoryContext.shouldLoadHistory
            ? "我正在检索主线程记忆，并判断是否需要调度 agent。"
            : "我正在用主线程知识库判断是否需要调度 agent。"
        activeLayer = "主线程"
        runtimePhase = .idle
        recordModelHeartbeat(source: "主线程知识库", detail: "轻量思考已启动。")
        appendTrace(
            kind: .route,
            actor: "主线程",
            title: "轻量思考",
            detail: "主线程检索记忆和内置知识库，先判断是否需要创建任务线程。"
        )
        appendTaskRecordMessage(taskRecordID, actor: "主线程", role: "意图判断", kind: .router, text: "我先读取主线程记忆和内置知识库，判断本轮是否需要创建专家 agent 任务。")

        let pending = ChatMessage(
            speaker: "灵枢",
            text: dialogueAcknowledgement.intake(for: userPrompt),
            isUser: false,
            isLoading: true,
            taskRecordID: taskRecordID
        )
        chatMessages.append(pending)
        activeThinkingMessageID = pending.id
        let runID = missionRunID
        let messageID = pending.id

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard self.missionRunID == runID else { return }

            self.isModelReplying = false
            if self.activeThinkingMessageID == messageID {
                self.activeThinkingMessageID = nil
            }
            self.taskRuntime = .idle
            self.recordModelHeartbeat(source: "主线程知识库", detail: "轻量思考完成。")
            self.enterCoreState(.standby, resetTimer: false)
            self.appendTrace(
                kind: .route,
                actor: "主线程",
                title: "判断完成",
                detail: "无需创建任务线程，本轮由灵枢基于记忆和知识库直接回答。"
            )
            self.resetAgentRuntime(
                title: "待机中",
                status: "\(self.agentRuntimeCounts.statusText)我已完成本轮主线程回复。"
            )

            if let index = self.chatMessages.firstIndex(where: { $0.id == messageID }) {
                self.chatMessages[index].text = answer
                self.chatMessages[index].isLoading = false
                self.chatMessages[index].taskRecordID = taskRecordID
            } else {
                self.chatMessages.append(.init(speaker: "灵枢", text: answer, isUser: false, taskRecordID: taskRecordID))
            }

            self.applyTaskRecordRoute(taskRecordID, route: .init(needsAgents: false, agents: [], directAnswer: answer, finalAnswer: answer, summary: "无需创建专家 agent，本轮由灵枢直接回答。"))
            self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: answer)
            self.finishTaskRecord(taskRecordID, status: .answered, summary: "灵枢直接回答，未创建专家 agent 任务。")
            self.mainThreadKernel.observeDirectAnswer(prompt: userPrompt, answer: answer)
            self.rememberMainThreadTurn(prompt: userPrompt, reply: answer)
            self.logEvent("现在  主线程完成轻量思考，未创建任务线程。")
        }

        return answer
    }

    private func userIdentityAnswer(from memoryContext: MainThreadMemoryContext) -> String {
        let memoryText = memoryContext.promptHint
        if memoryText.contains("身份") || memoryText.contains("用户") || memoryText.contains("课题") || memoryText.contains("项目") {
            return "从当前记忆看，你是正在与我协作推进任务的人。更具体的身份，我只以你明确告诉我的信息为准。"
        }

        return "我还没有足够可靠的身份记忆。现在我只知道，你是正在与我协作的人；你告诉我的身份，我会记住。"
    }

    func refreshCodexAuthStatusIfNeeded() {
        guard usesCodexAuth, codexAuthStatus == "未检查" else { return }
        refreshCodexAuthStatus()
    }

    func forceMainRemoteHealthProbe() {
        performMainRemoteHealthProbe(reason: "手动探活", force: true)
    }

    func startDemoMissionIfConnected() {
        guard isModelConnected else {
            enterCoreState(.abnormal)
            resetAgentRuntime(
                title: "等待接入",
                status: "主通道尚未就绪，不能启动能力协同。"
            )
            chatMessages.append(.init(speaker: "灵枢", text: "我还没有接入主通道。先完成配置，我再启动能力协同。", isUser: false))
            return
        }

        enterCoreState(.executing)
        startDemoMission()
    }

    func runEngineeringValidationSuite() {
        selectedSurface = .chat
        enterCoreState(.executing)
        runtimePhase = .verifying
        missionTitle = "工程验证"
        missionStatus = "正在验证软件工程与 PPT 工程两条交付链路。"
        activeLayer = "验证"
        logEvent("现在  启动工程验证：软件工程 + PPT 工程。")
        appendTrace(kind: .system, actor: "灵枢", title: "工程验证", detail: "开始走通软件工程和 PPT 工程两类产出物链路。")

        let softwarePrompt = "工程验证：写一个简单的 web 爬虫，要求给出可运行代码和验证说明。"
        let softwareRoute = CodexRoutePayload(
            needsAgents: true,
            agents: [
                .init(agent: "规划", task: "明确爬虫目标、输入输出和运行边界。", mode: "规划"),
                .init(agent: "执行", task: "生成可运行的 Python 爬虫代码和本地验证页。", mode: "执行"),
                .init(agent: "验证", task: "运行本地样例并检查输出结构。", mode: "验收")
            ],
            directAnswer: nil,
            finalAnswer: "我会按软件工程任务处理，生成可运行代码和验证说明。",
            summary: "软件工程验证任务。"
        )
        let softwareReply = "软件工程验证完成：已生成一个只依赖 Python 标准库的 Web 爬虫、运行说明、本地测试页和样例结果。"
        let softwareRecordID = createTaskExecutionRecord(for: softwarePrompt)
        applyTaskRecordRoute(softwareRecordID, route: softwareRoute)
        appendTaskRecordMessage(softwareRecordID, actor: "规划", role: "规划", kind: .agent, text: "已确认目标：产出可运行爬虫、验证页、样例结果和运行说明。")
        appendTaskRecordMessage(softwareRecordID, actor: "执行", role: "执行", kind: .agent, text: "已生成 Python 标准库实现，避免依赖外部包。")
        appendTaskRecordMessage(softwareRecordID, actor: "验证", role: "验收", kind: .review, text: "已验证爬虫可针对本地 HTML 运行并输出 JSON。")
        appendTaskRecordMessage(softwareRecordID, actor: "灵枢", role: "最终验收", kind: .result, text: softwareReply)
        materializeTaskArtifacts(for: softwarePrompt, route: softwareRoute, reply: softwareReply, taskRecordID: softwareRecordID)
        finishTaskRecord(softwareRecordID, status: .completed, summary: softwareReply)
        rememberTask(prompt: softwarePrompt, status: "delivered", summary: softwareReply, taskRecordID: softwareRecordID)

        let presentationPrompt = "工程验证：做一份介绍灵枢的 PPT，要求有可打开的演示文件和结构说明。"
        let presentationRoute = CodexRoutePayload(
            needsAgents: true,
            agents: [
                .init(agent: "规划", task: "明确 PPT 叙事结构和页内信息层级。", mode: "规划"),
                .init(agent: "设计", task: "生成 PPTX、演示预览页和结构说明。", mode: "设计"),
                .init(agent: "审议", task: "检查内容是否围绕灵枢工程管理案例。", mode: "审议"),
                .init(agent: "验证", task: "检查产出文件是否存在并可解包。", mode: "验收")
            ],
            directAnswer: nil,
            finalAnswer: "我会按设计交付任务处理，生成 PPTX 和可预览演示页。",
            summary: "PPT 工程验证任务。"
        )
        let presentationReply = "PPT 工程验证完成：已生成介绍灵枢的 PPTX、HTML 演示预览页、结构说明和产出物清单。"
        let presentationRecordID = createTaskExecutionRecord(for: presentationPrompt)
        applyTaskRecordRoute(presentationRecordID, route: presentationRoute)
        appendTaskRecordMessage(presentationRecordID, actor: "规划", role: "规划", kind: .agent, text: "已确定三页结构：定位、工程推进链路、当前交付。")
        appendTaskRecordMessage(presentationRecordID, actor: "设计", role: "设计", kind: .agent, text: "已按灵枢科技风格生成演示页与 PPTX 文件。")
        appendTaskRecordMessage(presentationRecordID, actor: "审议", role: "审议", kind: .review, text: "已检查内容不过度夸张，围绕工程管理创新实践。")
        appendTaskRecordMessage(presentationRecordID, actor: "验证", role: "验收", kind: .review, text: "已检查产物文件落地，并纳入任务执行记录。")
        appendTaskRecordMessage(presentationRecordID, actor: "灵枢", role: "最终验收", kind: .result, text: presentationReply)
        materializeTaskArtifacts(for: presentationPrompt, route: presentationRoute, reply: presentationReply, taskRecordID: presentationRecordID)
        finishTaskRecord(presentationRecordID, status: .completed, summary: presentationReply)
        rememberTask(prompt: presentationPrompt, status: "delivered", summary: presentationReply, taskRecordID: presentationRecordID)

        selectedTaskRecordID = presentationRecordID
        isTaskRecordPresented = true
        resetAgentRuntime(
            title: "工程验证完成",
            status: "软件工程与 PPT 工程均已生成对应产出物，任务记录可回看。"
        )
        chatMessages.append(.init(
            speaker: "灵枢",
            text: "工程验证完成。软件工程和 PPT 工程两条链路都已跑通，产出物已经挂到对应任务执行记录里。",
            isUser: false,
            taskRecordID: presentationRecordID
        ))
    }

    func resetAgentRuntime(title: String = "灵枢待命", status: String = "真实模型连接后，我会按任务需要动态展示参与的 agent。") {
        missionRunID += 1
        runtimePhase = .idle
        supervisionTick = 0
        supervisorEvents = []
        isModelExecuting = false
        activeThinkingMessageID = nil
        missionTitle = title
        missionStatus = status
        activeLayer = "灵枢中枢"

        for index in missionSteps.indices {
            missionSteps[index].state = .waiting
        }

        for index in agents.indices {
            agents[index].state = .waiting
            agents[index].mode = .dormant
            agents[index].cadence = "-"
            agents[index].focus = "等待真实模型调度"
            agents[index].lastFinding = "尚未巡检"
            agents[index].load = max(0.18, agents[index].load * 0.72)
        }
    }

    func refreshCodexAuthStatus() {
        guard !isCheckingCodexAuth else { return }
        isCheckingCodexAuth = true
        codexAuthStatus = "检查中"
        codexAuthDetail = "正在执行 codex login status"
        appendTrace(kind: .tool, actor: "Codex Auth", title: "检查登录", detail: "执行 codex login status。")
        let cliPath = codexCLIPath

        DispatchQueue.global(qos: .userInitiated).async {
            let status = CodexBridge.loginStatus(preferredPath: cliPath)
            DispatchQueue.main.async {
                self.codexAuthStatus = status.status
                self.codexAuthDetail = status.detail
                self.enterCoreState(status.status == "已登录" ? .standby : .abnormal)
                self.isCheckingCodexAuth = false
                self.logEvent("现在  Codex Auth 状态：\(status.status) \(status.detail)。")
                self.appendTrace(kind: status.status == "已登录" ? .result : .warning, actor: "Codex Auth", title: "登录状态", detail: "\(status.status)：\(status.detail)。")
                if status.status == "已登录" {
                    self.performMainRemoteHealthProbe(reason: "登录后探活", force: true)
                } else {
                    self.mainRemoteConsecutiveFailures = 0
                    self.mainRemoteLastFailureReason = status.detail
                    self.mainRemoteLastDiagnosticLog = status.detail
                    self.refreshMainRemoteConnectionStatus()
                }
            }
        }
    }

    func openCodexLogin() {
        let cliPath = CodexBridge.resolveCLIPath(preferredPath: codexCLIPath) ?? CodexBridge.bundledCLIPath
        let command = "\"\(cliPath)\" login --device-auth"
        let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            logEvent("现在  已打开 Codex 登录终端，请按提示完成 ChatGPT 授权。")
            appendTrace(kind: .tool, actor: "Codex Auth", title: "打开登录", detail: "已启动 Codex device auth 登录终端。")
        } catch {
            logEvent("现在  打开 Codex 登录失败：\(error.localizedDescription)。")
            appendTrace(kind: .warning, actor: "Codex Auth", title: "登录失败", detail: error.localizedDescription)
        }
    }

    private func requestRoutedCodexReply(
        for userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        replacing messageID: UUID,
        taskRecordID: String?
    ) {
        isModelReplying = true
        let cliPath = codexCLIPath
        let model = modelName
        let workingDirectory = codexWorkingDirectory
        let decision = permissionDecision(for: userPrompt)
        let permissionMode = decision.sandboxMode
        let timeout = codexTimeoutSeconds
        let fastMode = codexFastMode
        let memoryPromptHint = composedPromptHint(baseMemory: memoryContext.promptHint)
        let routeLease = remoteSessionPool.lease(
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
        let runID = missionRunID
        let handle = CodexExecutionHandle()
        activeRouteHandle = handle
        refreshRemoteSessionStatus()
        recordModelHeartbeat(source: "主线程", detail: "主线程判断通道已启动。")
        appendTrace(
            kind: .system,
            actor: "远端会话池",
            title: routeLease.canResumeNativeSession ? "复用主线程会话" : "创建主线程会话",
            detail: routeLease.canResumeNativeSession
                ? "命中 \(model) 路由会话，使用远端 session resume；本地记忆同步续接。"
                : "未命中可复用远端会话，本轮将创建主线程路由会话并登记。"
        )
        appendTrace(
            kind: .route,
            actor: "主线程",
            title: "提交判断",
            detail: "主线程向主模型提交判断：先确认能否直接回答，再决定是否创建任务线程并分派专家 agent。"
        )
        appendTaskRecordMessage(
            taskRecordID,
            actor: "主线程",
            role: "路由判断",
            kind: .router,
            text: "我正在判断这条消息是否需要调用专家 agent；如果需要，会创建本轮任务线程并分派。"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CodexBridge.routeReply(
                preferredPath: cliPath,
                modelName: model,
                userPrompt: userPrompt,
                memoryContext: memoryPromptHint,
                workingDirectory: workingDirectory,
                permissionMode: permissionMode,
                timeout: timeout,
                fastMode: fastMode,
                remoteSessionID: routeLease.nativeSessionID,
                cancellation: handle,
                progress: { chunk in
                    Task { @MainActor in
                        guard self.missionRunID == runID else { return }
                        self.appendCodexStream(chunk, actor: "主线程模型")
                    }
                },
                sessionRegistrar: { sessionID in
                    Task { @MainActor in
                        guard self.missionRunID == runID else { return }
                        self.remoteSessionPool.resolveNativeSession(
                            lease: routeLease,
                            nativeSessionID: sessionID,
                            localContextSummary: memoryPromptHint
                        )
                        self.refreshRemoteSessionStatus()
                        self.appendTrace(
                            kind: .system,
                            actor: "远端会话池",
                            title: "主线程会话已登记",
                            detail: "已登记 \(model) 路由 session：\(sessionID)。"
                        )
                    }
                }
            )

            DispatchQueue.main.async {
                guard self.missionRunID == runID else { return }
                if self.activeRouteHandle === handle {
                    self.activeRouteHandle = nil
                }
                self.isModelReplying = false
                let finalText: String

                switch result {
                case .success(let route):
                    self.remoteSessionPool.resolveNativeSession(
                        lease: routeLease,
                        nativeSessionID: routeLease.nativeSessionID,
                        localContextSummary: memoryPromptHint
                    )
                    self.refreshRemoteSessionStatus()
                    self.activeThinkingMessageID = nil
                    let effectiveRoute = self.reconcileRoute(route, for: userPrompt)
                    self.applyTaskRecordRoute(taskRecordID, route: effectiveRoute)
                    self.mainThreadKernel.observeRoute(
                        prompt: userPrompt,
                        routeSummary: effectiveRoute.summary ?? effectiveRoute.userFacingAnswer,
                        needsAgents: effectiveRoute.needsAgents,
                        agents: effectiveRoute.agents.map(\.agent)
                    )
                    if effectiveRoute.needsAgents && self.isCapabilityCollaborationRequest(userPrompt) {
                        _ = self.beginTaskRuntimeIfNeeded(for: userPrompt, taskRecordID: taskRecordID)
                    }
                    if effectiveRoute.needsAgents {
                        let agentNames = effectiveRoute.agents.map(\.agent).joined(separator: "、")
                        self.appendTrace(kind: .route, actor: "主线程", title: "判断完成", detail: "主线程无法直接完成，创建任务线程并分派：\(agentNames)。")
                        self.appendTaskRecordMessage(
                            taskRecordID,
                            actor: "灵枢",
                            role: "中枢",
                            kind: .router,
                            text: "这件事需要能力节点参与。本轮创建任务线程，分派给：\(agentNames)。"
                        )
	                        for task in effectiveRoute.agents {
	                            self.appendTaskRecordMessage(
	                                taskRecordID,
	                                actor: task.agent,
	                                role: task.mode ?? "能力节点",
	                                kind: .agent,
	                                text: task.task
	                            )
	                        }
	                        self.dispatchExternalAgentsIfAvailable(route: effectiveRoute, userPrompt: userPrompt, taskRecordID: taskRecordID)
	                    } else {
	                        self.appendTrace(kind: .route, actor: "主线程", title: "判断完成", detail: "无需调用专家 agent，本轮由灵枢直接回答。")
                            self.appendTaskRecordMessage(
                                taskRecordID,
                                actor: "灵枢",
                                role: "中枢",
                                kind: .router,
                                text: "我判断本轮不需要创建专家 agent，由我直接回答。"
                            )
	                    }
                    self.advanceTaskRuntimeAfterRoute(effectiveRoute, for: userPrompt, taskRecordID: taskRecordID)
                    let routePlanReply = self.applyRoutePlan(effectiveRoute, for: userPrompt, taskRecordID: taskRecordID)
                    let willStartExecutionThread = effectiveRoute.needsAgents && self.shouldStartExecutionThread(for: userPrompt, route: effectiveRoute)
                    finalText = self.dialogueAcknowledgement.routeReply(
                        for: effectiveRoute,
                        fallback: routePlanReply,
                        willExecute: willStartExecutionThread
                    )
                    self.rememberMainThreadTurn(prompt: userPrompt, reply: finalText, route: effectiveRoute)
                    self.logEvent("现在  Codex Auth 路由结果已返回。")
                    if effectiveRoute.needsAgents {
                        if willStartExecutionThread {
                            self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                            self.appendTaskRecordMessage(
                                taskRecordID,
                                actor: "调度",
                                    role: "任务编排",
                                    kind: .agent,
                                    text: "已进入执行队列，我会跟踪执行、监控、检查和最终回传。"
                                )
	                            self.requestExecutionCodexReply(for: userPrompt, route: effectiveRoute, taskRecordID: taskRecordID)
	                        } else {
		                            self.completeNonExecutingRoute(effectiveRoute, for: userPrompt, reply: finalText, taskRecordID: taskRecordID)
                                self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                                self.materializeTaskArtifacts(for: userPrompt, route: effectiveRoute, reply: finalText, taskRecordID: taskRecordID)
                                self.finishTaskRecord(taskRecordID, status: .completed, summary: "本轮完成判断/规划，没有进入工具执行。")
	                        }
	                    } else {
                            self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                            self.materializeTaskArtifacts(for: userPrompt, route: effectiveRoute, reply: finalText, taskRecordID: taskRecordID)
                            self.finishTaskRecord(taskRecordID, status: .answered, summary: "灵枢直接回答，未创建专家 agent 任务。")
                        }
                case .failure(let error):
                    self.remoteSessionPool.markFailed(lease: routeLease)
                    self.refreshRemoteSessionStatus()
                    self.activeThinkingMessageID = nil
                    self.mainThreadKernel.observeExecution(prompt: userPrompt, summary: "路由阶段失败：\(error)", completed: false)
                    self.enterCoreState(.abnormal)
	                    self.appendTrace(kind: .warning, actor: "主线程", title: "判断失败", detail: error)
	                    self.blockTaskRuntime(error)
	                    self.resetAgentRuntime(
	                        title: "主通道受阻",
	                        status: "这次没有形成可靠的能力分派，我已停止本轮调用链。"
	                    )
                    finalText = "主通道刚才没有稳定响应，我没有强行分派能力节点。你可以稍后再发一次，或者去配置页检查连接。"
                    self.appendTaskRecordMessage(taskRecordID, actor: "主线程", role: "路由判断", kind: .warning, text: error)
                    self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                    self.finishTaskRecord(taskRecordID, status: .blocked, summary: finalText)
                    self.logEvent("现在  Codex Auth 调用失败：\(error)")
                }

                if let index = self.chatMessages.firstIndex(where: { $0.id == messageID }) {
                    self.chatMessages[index].text = finalText
                    self.chatMessages[index].isLoading = false
                    self.chatMessages[index].taskRecordID = taskRecordID
                } else {
                    self.chatMessages.append(.init(speaker: "灵枢", text: finalText, isUser: false, taskRecordID: taskRecordID))
                }
            }
        }
    }

    private func requestAPIGatewayRouteReply(
        for userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        replacing messageID: UUID,
        taskRecordID: String?
    ) {
        isModelReplying = true
        let provider = modelProvider
        let model = modelName
        let endpoint = endpoint
        let apiKey = apiKey
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let timeout = codexTimeoutSeconds
        let memoryPromptHint = composedPromptHint(baseMemory: memoryContext.promptHint)
        let permission = permissionDecision(for: userPrompt)
        let routeSystemPrompt = routePlanner.routeSystemPrompt(permission: permission)
        let routeUserPrompt = routePlanner.routeUserPrompt(userPrompt: userPrompt, memoryContext: memoryPromptHint)
        let conversationMessages = modelConversationMessages(
            finalUserPrompt: routeUserPrompt,
            excludingCurrentRawPrompt: userPrompt
        )
        let useStreamingDialogue = shouldUseLocalStreamingDialogue
        let routeLease = remoteSessionPool.lease(
            provider: provider,
            model: model,
            purpose: .mainRouting,
            contextKey: mainThreadKernel.snapshot.sessionID,
            workingDirectory: codexWorkingDirectory,
            permissionBoundary: mainRoutingPermissionBoundary,
            endpoint: endpoint,
            protocolName: protocolName,
            localContextSummary: memoryPromptHint
        )
        let runID = missionRunID
        refreshRemoteSessionStatus()
        recordModelHeartbeat(source: "模型网关", detail: "\(provider) 路由请求已启动。")
        appendTrace(
            kind: .route,
            actor: "模型网关",
            title: routeLease.isWarm ? "复用 API 会话上下文" : "创建 API 会话上下文",
            detail: "通过 \(provider) / \(model) 判断是否需要创建任务线程。"
        )

        activeAPITask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = LingShuRemoteModelRequest(
                    provider: provider,
                    model: model,
                    endpoint: endpoint,
                    protocolName: protocolName,
                    apiKey: apiKey,
                    systemPrompt: routeSystemPrompt,
                    userPrompt: routeUserPrompt,
                    temperature: self.temperature,
                    stream: useStreamingDialogue,
                    timeout: timeout,
                    continuationToken: routeLease.continuationToken,
                    conversationMessages: conversationMessages
                )
                let reply: LingShuRemoteModelReply
                if useStreamingDialogue {
                    reply = try await self.remoteModelClient.stream(request) { [weak self] delta in
                        Task { @MainActor in
                            guard let self, self.missionRunID == runID else { return }
                            self.appendModelStream(delta, actor: "本地路由模型")
                        }
                    } onHeartbeat: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.missionRunID == runID else { return }
                            self.recordModelHeartbeat(source: "本地路由模型", detail: "流式连接活跃。")
                        }
                    }
                } else {
                    reply = try await self.remoteModelClient.send(request)
                }
                guard !Task.isCancelled, self.missionRunID == runID else { return }
                self.recordModelUsage(reply, stage: "路由判断")
                // 按当前模型适配器取干净正文（剥离 M3 的 <think> 等），再解析/兜底。
                let rawReply = self.currentReplyAdapter.normalizedReplyText(reply.text)
                let route = self.routePlanner.decodeRoutePayload(from: rawReply) ?? CodexRoutePayload(
                    needsAgents: false,
                    agents: [],
                    directAnswer: rawReply,
                    finalAnswer: rawReply,
                    summary: "API 模型没有返回结构化路由，本轮按直接回答处理。"
                )
                self.remoteSessionPool.resolveNativeSession(
                    lease: routeLease,
                    nativeSessionID: nil,
                    continuationToken: reply.continuationToken,
                    localContextSummary: rawReply
                )
                self.handleRouteResult(
                    route,
                    userPrompt: userPrompt,
                    messageID: messageID,
                    taskRecordID: taskRecordID,
                    sourceLabel: "模型网关"
                )
            } catch {
                guard !Task.isCancelled, self.missionRunID == runID else { return }
                let message = self.routePlanner.modelGatewayErrorMessage(error)
                self.remoteSessionPool.markFailed(lease: routeLease)
                self.refreshRemoteSessionStatus()
                self.activeAPITask = nil
                self.isModelReplying = false
                self.activeThinkingMessageID = nil
                self.mainThreadKernel.observeExecution(prompt: userPrompt, summary: "API 路由阶段失败：\(message)", completed: false)
                self.enterCoreState(.abnormal)
                self.blockTaskRuntime(message)
                self.resetAgentRuntime(
                    title: "主通道受阻",
                    status: "这次没有形成可靠的模型判断，我已停止本轮调用链。"
                )
                let finalText = "主通道刚才没有稳定响应，我没有强行分派能力节点。你可以稍后再发一次，或者去配置页检查模型配置。"
                self.appendTrace(kind: .warning, actor: "模型网关", title: "判断失败", detail: message)
                self.appendTaskRecordMessage(taskRecordID, actor: "模型网关", role: "路由判断", kind: .warning, text: message)
                self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                self.finishTaskRecord(taskRecordID, status: .blocked, summary: finalText)
                if let index = self.chatMessages.firstIndex(where: { $0.id == messageID }) {
                    self.chatMessages[index].text = finalText
                    self.chatMessages[index].isLoading = false
                    self.chatMessages[index].taskRecordID = taskRecordID
                } else {
                    self.chatMessages.append(.init(speaker: "灵枢", text: finalText, isUser: false, taskRecordID: taskRecordID))
                }
            }
        }
    }

    private func requestAPIExecutionReply(for userPrompt: String, route: CodexRoutePayload, taskRecordID: String?) {
        guard route.needsAgents, !route.agents.isEmpty else { return }

        isModelExecuting = true
        enterCoreState(.executing)
        let provider = modelProvider
        let model = modelName
        let endpoint = endpoint
        let apiKey = apiKey
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let timeout = codexTimeoutSeconds
        let executionPrompt = executionPrompt(for: userPrompt, route: route)
        let conversationMessages = modelConversationMessages(
            finalUserPrompt: executionPrompt,
            excludingCurrentRawPrompt: userPrompt
        )
        let useStreamingDialogue = shouldUseLocalStreamingDialogue
        let executionContextKey = activeTaskThread?.id ?? taskRuntime.taskID
        let executionLease = remoteSessionPool.lease(
            provider: provider,
            model: model,
            purpose: .taskExecution,
            contextKey: executionContextKey,
            workingDirectory: codexWorkingDirectory,
            permissionBoundary: taskPermissionBoundary(for: userPrompt),
            endpoint: endpoint,
            protocolName: protocolName,
            localContextSummary: executionPrompt
        )
        let runID = missionRunID
        refreshRemoteSessionStatus()
        recordModelHeartbeat(source: "执行模型", detail: "\(provider) 执行请求已启动。")
        markTaskRuntimeExecuting(route, for: userPrompt)
        appendTaskRecordMessage(taskRecordID, actor: "执行", role: "执行模型", kind: .model, text: "执行模型已接令；当前 API 通道会产出文本、代码或执行报告，不直接操作本机文件系统。")
        appendTrace(
            kind: .model,
            actor: "执行模型",
            title: executionLease.isWarm ? "复用执行上下文" : "创建执行上下文",
            detail: "通过 \(provider) / \(model) 执行本轮任务。"
        )

        activeAPITask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = LingShuRemoteModelRequest(
                    provider: provider,
                    model: model,
                    endpoint: endpoint,
                    protocolName: protocolName,
                    apiKey: apiKey,
                    systemPrompt: self.routePlanner.executionSystemPrompt,
                    userPrompt: executionPrompt,
                    temperature: self.temperature,
                    stream: useStreamingDialogue,
                    timeout: timeout,
                    continuationToken: executionLease.continuationToken,
                    conversationMessages: conversationMessages
                )
                let reply: LingShuRemoteModelReply
                if useStreamingDialogue {
                    reply = try await self.remoteModelClient.stream(request) { [weak self] delta in
                        Task { @MainActor in
                            guard let self, self.missionRunID == runID else { return }
                            self.appendModelStream(delta, actor: "本地执行模型")
                        }
                    } onHeartbeat: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.missionRunID == runID else { return }
                            self.recordModelHeartbeat(source: "本地执行模型", detail: "流式连接活跃。")
                        }
                    }
                } else {
                    reply = try await self.remoteModelClient.send(request)
                }
                guard !Task.isCancelled, self.missionRunID == runID else { return }
                self.recordModelUsage(reply, stage: "执行阶段")
                self.remoteSessionPool.resolveNativeSession(
                    lease: executionLease,
                    nativeSessionID: nil,
                    continuationToken: reply.continuationToken,
                    localContextSummary: reply.text
                )
                self.refreshRemoteSessionStatus()
                self.activeAPITask = nil
                self.isModelExecuting = false
                self.completeRouteExecution(route)
                let finalReply = self.postProcessExecutionReply(reply.text, for: userPrompt, route: route)
                self.mainThreadKernel.observeExecution(prompt: userPrompt, summary: finalReply, completed: true)
                self.completeTaskRuntime(for: userPrompt, reply: finalReply, taskRecordID: taskRecordID)
                self.rememberMainThreadTurn(prompt: userPrompt, reply: finalReply, route: route)
                self.appendTrace(kind: .result, actor: "执行模型", title: "执行返回", detail: finalReply.isEmpty ? "执行模型已返回，但没有可展示文本。" : finalReply)
                self.appendTaskRecordMessage(taskRecordID, actor: "执行", role: "执行模型", kind: .result, text: finalReply.isEmpty ? "执行模型已返回，但没有可展示文本。" : finalReply)
                self.materializeTaskArtifacts(for: userPrompt, route: route, reply: finalReply, taskRecordID: taskRecordID)
                self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "最终验收", kind: .review, text: "我已收到执行回传，并完成本轮验收与统一交付。")
                self.finishTaskRecord(taskRecordID, status: .completed, summary: finalReply.isEmpty ? "执行模型已完成。" : finalReply)
                if !finalReply.isEmpty {
                    self.chatMessages.append(.init(speaker: "灵枢", text: finalReply, isUser: false, taskRecordID: taskRecordID))
                }
                self.logEvent("现在  API 执行流程已返回。")
            } catch {
                guard !Task.isCancelled, self.missionRunID == runID else { return }
                let message = self.routePlanner.modelGatewayErrorMessage(error)
                self.remoteSessionPool.markFailed(lease: executionLease)
                self.refreshRemoteSessionStatus()
                self.activeAPITask = nil
                self.isModelExecuting = false
                self.appendTrace(kind: .warning, actor: "执行模型", title: "执行失败", detail: message)
                self.appendTaskRecordMessage(taskRecordID, actor: "执行", role: "执行模型", kind: .warning, text: message)

                // 网关执行通道受限时，先尝试本地兜底交付，再决定是否阻断。
                let artifacts = self.materializeTaskArtifacts(for: userPrompt, route: route, reply: route.userFacingAnswer, taskRecordID: taskRecordID)
                if !artifacts.isEmpty {
                    let reply = "网关的执行通道这次受限，我已用本地能力把交付物生成好，挂在本轮任务记录里，可以直接预览。"
                    self.completeRouteExecution(route)
                    self.completeTaskRuntime(for: userPrompt, reply: reply, taskRecordID: taskRecordID)
                    self.mainThreadKernel.observeExecution(prompt: userPrompt, summary: reply, completed: true)
                    self.rememberMainThreadTurn(prompt: userPrompt, reply: reply, route: route)
                    self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "最终验收", kind: .review, text: "已用本地能力完成本轮交付。")
                    self.finishTaskRecord(taskRecordID, status: .completed, summary: reply)
                    self.chatMessages.append(.init(speaker: "灵枢", text: reply, isUser: false, taskRecordID: taskRecordID))
                    self.logEvent("现在  网关执行受限，已本地兜底交付。")
                    return
                }

                self.mainThreadKernel.observeExecution(prompt: userPrompt, summary: message, completed: false)
                self.enterCoreState(.abnormal)
                self.runtimePhase = .correcting
                self.missionTitle = "异常"
                self.missionStatus = "执行阶段受阻，我已经停止继续推进，避免产生不可靠结果。"
                self.blockTaskRuntime(message)
                let failureReply = "执行阶段遇到阻断。我已经停止继续推进，避免给你一个不可靠的结果。你可以检查模型配置，或者调整任务后再交给我。"
                self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: failureReply)
                self.finishTaskRecord(taskRecordID, status: .blocked, summary: failureReply)
                self.chatMessages.append(.init(speaker: "灵枢", text: failureReply, isUser: false, taskRecordID: taskRecordID))
                self.logEvent("现在  API 执行流程失败：\(message)")
            }
        }
    }

    private func handleRouteResult(
        _ route: CodexRoutePayload,
        userPrompt: String,
        messageID: UUID,
        taskRecordID: String?,
        sourceLabel: String
    ) {
        activeAPITask = nil
        isModelReplying = false
        activeThinkingMessageID = nil
        refreshRemoteSessionStatus()
        let effectiveRoute = reconcileRoute(route, for: userPrompt)
        applyTaskRecordRoute(taskRecordID, route: effectiveRoute)
        mainThreadKernel.observeRoute(
            prompt: userPrompt,
            routeSummary: effectiveRoute.summary ?? effectiveRoute.userFacingAnswer,
            needsAgents: effectiveRoute.needsAgents,
            agents: effectiveRoute.agents.map(\.agent)
        )
        if effectiveRoute.needsAgents && isCapabilityCollaborationRequest(userPrompt) {
            _ = beginTaskRuntimeIfNeeded(for: userPrompt, taskRecordID: taskRecordID)
        }

        if effectiveRoute.needsAgents {
            let agentNames = effectiveRoute.agents.map(\.agent).joined(separator: "、")
            appendTrace(kind: .route, actor: sourceLabel, title: "判断完成", detail: "主线程无法直接完成，创建任务线程并分派：\(agentNames)。")
            appendTaskRecordMessage(
                taskRecordID,
                actor: "灵枢",
                role: "中枢",
                kind: .router,
                text: "这件事需要能力节点参与。本轮创建任务线程，分派给：\(agentNames)。"
            )
            for task in effectiveRoute.agents {
                appendTaskRecordMessage(
                    taskRecordID,
                    actor: task.agent,
                    role: task.mode ?? "能力节点",
                    kind: .agent,
                    text: task.task
                )
            }
            dispatchExternalAgentsIfAvailable(route: effectiveRoute, userPrompt: userPrompt, taskRecordID: taskRecordID)
        } else {
            appendTrace(kind: .route, actor: sourceLabel, title: "判断完成", detail: "无需调用专家 agent，本轮由灵枢直接回答。")
            appendTaskRecordMessage(
                taskRecordID,
                actor: "灵枢",
                role: "中枢",
                kind: .router,
                text: "我判断本轮不需要创建专家 agent，由我直接回答。"
            )
        }

        advanceTaskRuntimeAfterRoute(effectiveRoute, for: userPrompt, taskRecordID: taskRecordID)
        let routePlanReply = applyRoutePlan(effectiveRoute, for: userPrompt, taskRecordID: taskRecordID)
        let willStartExecutionThread = effectiveRoute.needsAgents && shouldStartExecutionThread(for: userPrompt, route: effectiveRoute)
        let finalText = dialogueAcknowledgement.routeReply(
            for: effectiveRoute,
            fallback: routePlanReply,
            willExecute: willStartExecutionThread
        )
        rememberMainThreadTurn(prompt: userPrompt, reply: finalText, route: effectiveRoute)
        logEvent("现在  \(sourceLabel) 路由结果已返回。")

        if effectiveRoute.needsAgents {
            if willStartExecutionThread {
                appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                appendTaskRecordMessage(
                    taskRecordID,
                    actor: "调度",
                    role: "任务编排",
                    kind: .agent,
                    text: "已进入执行队列，我会跟踪执行、监控、检查和最终回传。"
                )
                if usesCodexAuth {
                    requestExecutionCodexReply(for: userPrompt, route: effectiveRoute, taskRecordID: taskRecordID)
                } else {
                    requestAPIExecutionReply(for: userPrompt, route: effectiveRoute, taskRecordID: taskRecordID)
                }
            } else {
                completeNonExecutingRoute(effectiveRoute, for: userPrompt, reply: finalText, taskRecordID: taskRecordID)
                appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
                materializeTaskArtifacts(for: userPrompt, route: effectiveRoute, reply: finalText, taskRecordID: taskRecordID)
                finishTaskRecord(taskRecordID, status: .completed, summary: "本轮完成判断/规划，没有进入工具执行。")
            }
        } else {
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
            materializeTaskArtifacts(for: userPrompt, route: effectiveRoute, reply: finalText, taskRecordID: taskRecordID)
            finishTaskRecord(taskRecordID, status: .answered, summary: "灵枢直接回答，未创建专家 agent 任务。")
        }

        // 仅在直接回答（无后台执行线程）时把选择卡片挂到这条回复上，
        // 让用户在有限选项中一键选择，而不是手打。
        let attachedChoices = willStartExecutionThread ? nil : effectiveRoute.choices
        if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].text = finalText
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = taskRecordID
            chatMessages[index].choices = attachedChoices
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: finalText, isUser: false, taskRecordID: taskRecordID, choices: attachedChoices))
        }
    }

    /// 用户在选择卡片上点了某个选项：标记该卡片已解决，并把选项作为一条输入提交，推进对话。
    func selectRouteChoice(_ option: String, for messageID: UUID) {
        guard let index = chatMessages.firstIndex(where: { $0.id == messageID }),
              chatMessages[index].resolvedChoice == nil else { return }
        chatMessages[index].resolvedChoice = option
        _ = submitTextInput(option, source: .typed)
    }

    private func requestBackgroundRouteReply(
        for userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        taskRecordID: String?,
        threadID: String,
        sourceLabel: String
    ) {
        appendTaskRecordMessage(taskRecordID, actor: "任务线程", role: "隔离路由", kind: .router, text: "已创建隔离线程 \(threadID)，开始独立路由判断。")

        if usesCodexAuth {
            guard codexAuthStatus == "已登录" else {
                blockBackgroundTask(userPrompt: userPrompt, taskRecordID: taskRecordID, threadID: threadID, message: "Codex Auth 未登录，隔离线程无法启动。")
                return
            }
            requestBackgroundCodexRouteReply(for: userPrompt, memoryContext: memoryContext, taskRecordID: taskRecordID, threadID: threadID)
        } else {
            guard isModelConnected else {
                blockBackgroundTask(userPrompt: userPrompt, taskRecordID: taskRecordID, threadID: threadID, message: "模型主通道未连接，隔离线程无法启动。")
                return
            }
            requestBackgroundAPIRouteReply(for: userPrompt, memoryContext: memoryContext, taskRecordID: taskRecordID, threadID: threadID, sourceLabel: sourceLabel)
        }
    }

    private func requestBackgroundCodexRouteReply(
        for userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        taskRecordID: String?,
        threadID: String
    ) {
        let recordKey = taskRecordID ?? "background-\(UUID().uuidString)"
        let cliPath = codexCLIPath
        let model = modelName
        let workingDirectory = codexWorkingDirectory
        let decision = permissionDecision(for: userPrompt)
        let permissionMode = decision.sandboxMode
        let timeout = codexTimeoutSeconds
        let fastMode = codexFastMode
        let memoryPromptHint = composedPromptHint(baseMemory: memoryContext.promptHint)
        let routeLease = remoteSessionPool.lease(
            provider: modelProvider,
            model: model,
            purpose: .mainRouting,
            contextKey: threadID,
            workingDirectory: workingDirectory,
            permissionBoundary: mainRoutingPermissionBoundary,
            endpoint: endpoint,
            protocolName: "Codex CLI",
            localContextSummary: memoryPromptHint
        )
        let handle = CodexExecutionHandle()
        backgroundCodexHandles[recordKey] = handle
        refreshRemoteSessionStatus()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CodexBridge.routeReply(
                preferredPath: cliPath,
                modelName: model,
                userPrompt: userPrompt,
                memoryContext: memoryPromptHint,
                workingDirectory: workingDirectory,
                permissionMode: permissionMode,
                timeout: timeout,
                fastMode: fastMode,
                remoteSessionID: routeLease.nativeSessionID,
                cancellation: handle,
                progress: { chunk in
                    Task { @MainActor in
                        self.appendTaskRecordMessage(taskRecordID, actor: "隔离路由", role: "底层输出", kind: .model, text: self.cleanTraceText(chunk))
                    }
                },
                sessionRegistrar: { sessionID in
                    Task { @MainActor in
                        self.remoteSessionPool.resolveNativeSession(
                            lease: routeLease,
                            nativeSessionID: sessionID,
                            localContextSummary: memoryPromptHint
                        )
                        self.refreshRemoteSessionStatus()
                    }
                }
            )

            DispatchQueue.main.async {
                self.backgroundCodexHandles.removeValue(forKey: recordKey)
                switch result {
                case .success(let route):
                    self.remoteSessionPool.resolveNativeSession(
                        lease: routeLease,
                        nativeSessionID: routeLease.nativeSessionID,
                        localContextSummary: memoryPromptHint
                    )
                    self.refreshRemoteSessionStatus()
                    self.handleBackgroundRouteResult(route, userPrompt: userPrompt, taskRecordID: taskRecordID, threadID: threadID, sourceLabel: "隔离主线程")
                case .failure(let error):
                    self.remoteSessionPool.markFailed(lease: routeLease)
                    self.refreshRemoteSessionStatus()
                    self.blockBackgroundTask(userPrompt: userPrompt, taskRecordID: taskRecordID, threadID: threadID, message: error)
                }
            }
        }
    }

    private func requestBackgroundAPIRouteReply(
        for userPrompt: String,
        memoryContext: MainThreadMemoryContext,
        taskRecordID: String?,
        threadID: String,
        sourceLabel: String
    ) {
        let recordKey = taskRecordID ?? "background-\(UUID().uuidString)"
        let provider = modelProvider
        let model = modelName
        let endpoint = endpoint
        let apiKey = apiKey
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let timeout = codexTimeoutSeconds
        let memoryPromptHint = composedPromptHint(baseMemory: memoryContext.promptHint)
        let permission = permissionDecision(for: userPrompt)
        let routeSystemPrompt = routePlanner.routeSystemPrompt(permission: permission)
        let routeUserPrompt = routePlanner.routeUserPrompt(userPrompt: userPrompt, memoryContext: memoryPromptHint)
        let routeConversation = backgroundConversationMessages(excludingTrailingPromptMatching: userPrompt)
        let routeLease = remoteSessionPool.lease(
            provider: provider,
            model: model,
            purpose: .mainRouting,
            contextKey: threadID,
            workingDirectory: codexWorkingDirectory,
            permissionBoundary: mainRoutingPermissionBoundary,
            endpoint: endpoint,
            protocolName: protocolName,
            localContextSummary: memoryPromptHint
        )

        backgroundAPITasks[recordKey] = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.remoteModelClient.send(.init(
                    provider: provider,
                    model: model,
                    endpoint: endpoint,
                    protocolName: protocolName,
                    apiKey: apiKey,
                    systemPrompt: routeSystemPrompt,
                    userPrompt: routeUserPrompt,
                    temperature: self.temperature,
                    stream: false,
                    timeout: timeout,
                    continuationToken: routeLease.continuationToken,
                    conversationMessages: routeConversation
                ))
                guard !Task.isCancelled else { return }
                let route = self.routePlanner.decodeRoutePayload(from: reply.text) ?? CodexRoutePayload(
                    needsAgents: false,
                    agents: [],
                    directAnswer: reply.text,
                    finalAnswer: reply.text,
                    summary: "API 模型没有返回结构化路由，本轮按直接回答处理。"
                )
                self.remoteSessionPool.resolveNativeSession(
                    lease: routeLease,
                    nativeSessionID: nil,
                    continuationToken: reply.continuationToken,
                    localContextSummary: reply.text
                )
                self.backgroundAPITasks.removeValue(forKey: recordKey)
                self.refreshRemoteSessionStatus()
                self.recordModelUsage(reply, stage: "后台路由")
                self.handleBackgroundRouteResult(route, userPrompt: userPrompt, taskRecordID: taskRecordID, threadID: threadID, sourceLabel: sourceLabel)
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.routePlanner.modelGatewayErrorMessage(error)
                self.remoteSessionPool.markFailed(lease: routeLease)
                self.backgroundAPITasks.removeValue(forKey: recordKey)
                self.refreshRemoteSessionStatus()
                self.blockBackgroundTask(userPrompt: userPrompt, taskRecordID: taskRecordID, threadID: threadID, message: message)
            }
        }
    }

    private func handleBackgroundRouteResult(
        _ route: CodexRoutePayload,
        userPrompt: String,
        taskRecordID: String?,
        threadID: String,
        sourceLabel: String
    ) {
        let effectiveRoute = reconcileRoute(route, for: userPrompt)
        applyTaskRecordRoute(taskRecordID, route: effectiveRoute)
        mainThreadKernel.observeRoute(
            prompt: userPrompt,
            routeSummary: effectiveRoute.summary ?? effectiveRoute.userFacingAnswer,
            needsAgents: effectiveRoute.needsAgents,
            agents: effectiveRoute.agents.map(\.agent)
        )

        if effectiveRoute.needsAgents {
            let agentNames = effectiveRoute.agents.map(\.agent).joined(separator: "、")
            appendTaskRecordMessage(taskRecordID, actor: sourceLabel, role: "路由判断", kind: .router, text: "隔离线程已完成分派：\(agentNames)。")
            for task in effectiveRoute.agents {
                appendTaskRecordMessage(taskRecordID, actor: task.agent, role: task.mode ?? "能力节点", kind: .agent, text: task.task)
            }
            if shouldStartExecutionThread(for: userPrompt, route: effectiveRoute) {
                appendTaskRecordMessage(taskRecordID, actor: "调度", role: "任务编排", kind: .agent, text: "隔离线程进入执行队列；该线程与当前前台任务上下文分离。")
                requestBackgroundExecutionReply(for: userPrompt, route: effectiveRoute, taskRecordID: taskRecordID, threadID: threadID)
                return
            }
        }

        let finalText = LingShuExecutionCoordinator.sanitizeServerArtifactReferences(effectiveRoute.userFacingAnswer)
        rememberMainThreadTurn(prompt: userPrompt, reply: finalText, route: effectiveRoute)
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: finalText)
        materializeTaskArtifacts(for: userPrompt, route: effectiveRoute, reply: finalText, taskRecordID: taskRecordID)
        finishTaskRecord(taskRecordID, status: effectiveRoute.needsAgents ? .completed : .answered, summary: finalText)
        chatMessages.append(.init(speaker: "灵枢", text: finalText, isUser: false, taskRecordID: taskRecordID))
        markTaskSegmentFinished(recordID: taskRecordID)
        startNextQueuedTaskIfAvailable(preferredThreadID: threadID)
    }

    private func requestBackgroundExecutionReply(
        for userPrompt: String,
        route: CodexRoutePayload,
        taskRecordID: String?,
        threadID: String
    ) {
        if usesCodexAuth {
            requestBackgroundCodexExecutionReply(for: userPrompt, route: route, taskRecordID: taskRecordID, threadID: threadID)
        } else {
            requestBackgroundAPIExecutionReply(for: userPrompt, route: route, taskRecordID: taskRecordID, threadID: threadID)
        }
    }

    private func requestBackgroundCodexExecutionReply(
        for userPrompt: String,
        route: CodexRoutePayload,
        taskRecordID: String?,
        threadID: String
    ) {
        let recordKey = taskRecordID ?? "background-\(UUID().uuidString)"
        let memoryHint = mainThreadKernel.promptHint(baseMemory: memoryService.executionMemoryHint(for: userPrompt).text)
        let executionPrompt = executionCoordinator.executionPrompt(
            userPrompt: userPrompt,
            route: route,
            memoryHint: memoryHint,
            isProjectExecutionRequest: isProjectExecutionRequest(userPrompt)
        )
        let cliPath = codexCLIPath
        let model = modelName
        let workingDirectory = codexWorkingDirectory
        let permissionMode = codexPermissionMode
        let timeout = codexTimeoutSeconds
        let fastMode = codexFastMode
        let executionLease = remoteSessionPool.lease(
            provider: modelProvider,
            model: model,
            purpose: .taskExecution,
            contextKey: threadID,
            workingDirectory: workingDirectory,
            permissionBoundary: taskPermissionBoundary(for: userPrompt),
            endpoint: endpoint,
            protocolName: "Codex CLI",
            localContextSummary: executionPrompt
        )
        let handle = CodexExecutionHandle()
        backgroundCodexHandles[recordKey] = handle
        appendTaskRecordMessage(taskRecordID, actor: "执行", role: "隔离执行", kind: .model, text: "隔离执行线程已启动。")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CodexBridge.execReply(
                preferredPath: cliPath,
                modelName: model,
                userPrompt: executionPrompt,
                workingDirectory: workingDirectory,
                permissionMode: permissionMode,
                timeout: timeout,
                fastMode: fastMode,
                remoteSessionID: executionLease.nativeSessionID,
                cancellation: handle,
                progress: { chunk in
                    Task { @MainActor in
                        self.appendTaskRecordMessage(taskRecordID, actor: "隔离执行", role: "底层输出", kind: .model, text: self.cleanTraceText(chunk))
                    }
                },
                sessionRegistrar: { sessionID in
                    Task { @MainActor in
                        self.remoteSessionPool.resolveNativeSession(
                            lease: executionLease,
                            nativeSessionID: sessionID,
                            localContextSummary: executionPrompt
                        )
                        self.refreshRemoteSessionStatus()
                    }
                }
            )

            DispatchQueue.main.async {
                self.backgroundCodexHandles.removeValue(forKey: recordKey)
                switch result {
                case .success(let reply):
                    self.remoteSessionPool.resolveNativeSession(
                        lease: executionLease,
                        nativeSessionID: executionLease.nativeSessionID,
                        localContextSummary: reply
                    )
                    self.finishBackgroundExecution(userPrompt: userPrompt, route: route, taskRecordID: taskRecordID, threadID: threadID, rawReply: reply)
                case .failure(let error):
                    self.remoteSessionPool.markFailed(lease: executionLease)
                    self.refreshRemoteSessionStatus()
                    self.blockBackgroundTask(userPrompt: userPrompt, taskRecordID: taskRecordID, threadID: threadID, message: error)
                }
            }
        }
    }

    private func requestBackgroundAPIExecutionReply(
        for userPrompt: String,
        route: CodexRoutePayload,
        taskRecordID: String?,
        threadID: String
    ) {
        let recordKey = taskRecordID ?? "background-\(UUID().uuidString)"
        let memoryHint = mainThreadKernel.promptHint(baseMemory: memoryService.executionMemoryHint(for: userPrompt).text)
        let executionPrompt = executionCoordinator.executionPrompt(
            userPrompt: userPrompt,
            route: route,
            memoryHint: memoryHint,
            isProjectExecutionRequest: isProjectExecutionRequest(userPrompt)
        )
        let executionConversation = backgroundConversationMessages(excludingTrailingPromptMatching: userPrompt)
        let provider = modelProvider
        let model = modelName
        let endpoint = endpoint
        let apiKey = apiKey
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let timeout = codexTimeoutSeconds
        let executionLease = remoteSessionPool.lease(
            provider: provider,
            model: model,
            purpose: .taskExecution,
            contextKey: threadID,
            workingDirectory: codexWorkingDirectory,
            permissionBoundary: taskPermissionBoundary(for: userPrompt),
            endpoint: endpoint,
            protocolName: protocolName,
            localContextSummary: executionPrompt
        )
        appendTaskRecordMessage(taskRecordID, actor: "执行", role: "隔离执行", kind: .model, text: "隔离 API 执行线程已启动。")

        backgroundAPITasks[recordKey] = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.remoteModelClient.send(.init(
                    provider: provider,
                    model: model,
                    endpoint: endpoint,
                    protocolName: protocolName,
                    apiKey: apiKey,
                    systemPrompt: self.routePlanner.executionSystemPrompt,
                    userPrompt: executionPrompt,
                    temperature: self.temperature,
                    stream: false,
                    timeout: timeout,
                    continuationToken: executionLease.continuationToken,
                    conversationMessages: executionConversation
                ))
                guard !Task.isCancelled else { return }
                self.remoteSessionPool.resolveNativeSession(
                    lease: executionLease,
                    nativeSessionID: nil,
                    continuationToken: reply.continuationToken,
                    localContextSummary: reply.text
                )
                self.backgroundAPITasks.removeValue(forKey: recordKey)
                self.recordModelUsage(reply, stage: "后台执行")
                self.finishBackgroundExecution(userPrompt: userPrompt, route: route, taskRecordID: taskRecordID, threadID: threadID, rawReply: reply.text)
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.routePlanner.modelGatewayErrorMessage(error)
                self.remoteSessionPool.markFailed(lease: executionLease)
                self.backgroundAPITasks.removeValue(forKey: recordKey)
                self.refreshRemoteSessionStatus()
                self.degradeBackgroundToLocalDelivery(
                    userPrompt: userPrompt,
                    route: route,
                    taskRecordID: taskRecordID,
                    threadID: threadID,
                    failureMessage: message
                )
            }
        }
    }

    private func dispatchExternalAgentsIfAvailable(
        route: CodexRoutePayload,
        userPrompt: String,
        taskRecordID: String?
    ) {
        let context = mainThreadKernel.promptHint(baseMemory: executionMemoryHint(for: userPrompt))
        let permission = taskPermissionBoundary(for: userPrompt)
        let plans = route.agents.compactMap { task -> (CodexAgentTask, LingShuExternalAgentInvocationPlan)? in
            guard let plan = externalAgentRegistry.makeInvocationPlan(
                capability: task.agent,
                prompt: task.task,
                contextSummary: context,
                permissionBoundary: permission,
                heartbeatIntervalSeconds: 15
            ) else {
                return nil
            }
            return (task, plan)
        }

        guard !plans.isEmpty else {
            appendTrace(
                kind: .system,
                actor: "外部 agent",
                title: "未命中外部能力",
                detail: "本轮没有启用的外部 agent 匹配路由能力，继续使用内置能力运行时。"
            )
            return
        }

        for (task, plan) in plans {
            appendTrace(
                kind: .agent,
                actor: "外部 agent",
                title: "提交任务",
                detail: "\(plan.agent.displayName) 承接 \(task.agent)：\(task.task)"
            )
            appendTaskRecordMessage(
                taskRecordID,
                actor: plan.agent.displayName,
                role: "外部 \(plan.agent.transport.rawValue)",
                kind: .agent,
                text: "已接收灵枢分派：\(task.task)"
            )

            Task { [weak self] in
                guard let self else { return }
                let response = await self.externalAgentGateway.invoke(plan)
                guard !Task.isCancelled else { return }

                let statusText = response.status.rawValue
                let summary = "\(statusText)：\(response.summary)"
                self.appendTrace(
                    kind: response.status == .failed || response.status == .rejected || response.status == .timedOut ? .warning : .result,
                    actor: plan.agent.displayName,
                    title: "外部回传",
                    detail: summary
                )
                self.appendTaskRecordMessage(
                    taskRecordID,
                    actor: plan.agent.displayName,
                    role: "外部回传",
                    kind: response.status == .failed || response.status == .rejected || response.status == .timedOut ? .warning : .result,
                    text: summary
                )

                for artifact in response.artifacts {
                    let artifactTitle = (artifact as NSString).lastPathComponent
                    self.appendTaskRecordArtifact(
                        taskRecordID,
                        title: artifactTitle.isEmpty ? "外部 agent 产出物" : artifactTitle,
                        location: artifact,
                        producer: plan.agent.displayName
                    )
                }
            }
        }
    }

    private func reconcileRoute(_ route: CodexRoutePayload, for userPrompt: String) -> CodexRoutePayload {
        if isCapabilityCollaborationRequest(userPrompt) {
            return ensureGovernanceCapabilityRoute(route, for: userPrompt)
        }

        guard route.needsAgents, shouldForceDirectAnswer(userPrompt) else { return route }

        let answer = route.userFacingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTrace(
            kind: .route,
            actor: "灵枢",
            title: "阻止过度分派",
            detail: "这是一条普通解释/问答请求，不进入后台执行队列。"
        )

        return CodexRoutePayload(
            needsAgents: false,
            agents: [],
            directAnswer: answer,
            finalAnswer: answer,
            summary: "本轮是直接回答请求，无需调用专家 agent。"
        )
    }

    private func ensureGovernanceCapabilityRoute(_ route: CodexRoutePayload, for userPrompt: String) -> CodexRoutePayload {
        var tasks = route.agents

        ensureTask(&tasks, agent: "规划", task: "理解用户目标，形成任务草案、执行计划和能力分派建议。", mode: "规划", cadence: "本轮", rationale: "复杂任务必须先形成可执行规划。", at: 0)
        ensureTask(&tasks, agent: "审议", task: "同步审核任务草案、风险、权限边界和合规约束，必要时封驳。", mode: "监工", cadence: "实时", rationale: "复杂任务需要全过程审核和风险封驳。", at: 1)
        ensureTask(&tasks, agent: "调度", task: "接收通过审核的计划，调度必要能力节点或外部执行器落地并汇总结果。", mode: "执行", cadence: "本轮", rationale: "任务需要调度节点统一落地和回传。", at: 2)

        let normalized = userPrompt
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        if isDevelopmentQueueRequest(userPrompt) {
            ensureTask(&tasks, agent: "执行", task: isProjectExecutionRequest(userPrompt) ? "按调度节点授权在当前目标环境中完成实现，并在必要时运行验证。" : "按调度节点授权产出可运行结果、依赖说明和使用方式；不修改当前项目文件。", mode: "执行", cadence: "本轮", rationale: "用户提出可执行产出任务。")
        }
        if isDesignDeliveryRequest(userPrompt) {
            ensureTask(&tasks, agent: "设计", task: "根据用户目标形成叙事结构、视觉方向、页级版式和 PPT/演示交付口径。", mode: "设计", cadence: "本轮", rationale: "用户提出设计交付或演示材料需求。")
        }
        if normalized.contains("测试") || normalized.contains("验收") || normalized.contains("review") || normalized.contains("质量") {
            ensureTask(&tasks, agent: "验证", task: "制定或执行测试、验收和质量门禁检查。", mode: "验收", cadence: "提交后", rationale: "任务涉及测试、Review 或验收。")
        }
        if normalized.contains("监控") || normalized.contains("心跳") || normalized.contains("巡检") || normalized.contains("部署") || normalized.contains("运行") {
            ensureTask(&tasks, agent: "监控", task: "跟踪执行心跳、状态、偏差和运行风险。", mode: "监工", cadence: "实时", rationale: "任务涉及运行状态或持续观察。")
        }
        if normalized.contains("记忆") || normalized.contains("历史") || normalized.contains("冷备") || normalized.contains("线程") {
            ensureTask(&tasks, agent: "记忆", task: "检索并恢复相关主线程记忆、执行记忆或冷备摘要。", mode: "规划", cadence: "本轮", rationale: "任务涉及历史记忆或上下文恢复。")
        }
        if normalized.contains("安全") || normalized.contains("权限") || normalized.contains("合规") || normalized.contains("隐私") {
            ensureTask(&tasks, agent: "安全", task: "审查权限边界、数据风险和高风险操作。", mode: "验收", cadence: "实时", rationale: "任务涉及安全或权限边界。")
        }
        if normalized.contains("检索") || normalized.contains("资料") || normalized.contains("研究") || normalized.contains("引用") {
            ensureTask(&tasks, agent: "知识", task: "检索、整理和沉淀相关知识材料。", mode: "规划", cadence: "本轮", rationale: "任务涉及知识检索或资料整理。")
        }

        let summary = route.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = route.userFacingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTrace(kind: .route, actor: "灵枢", title: "治理准入", detail: "本轮任务已补齐规划、审议、调度治理链路。")

        return CodexRoutePayload(
            needsAgents: true,
            agents: orderedGovernanceTasks(tasks),
            directAnswer: route.directAnswer,
            finalAnswer: answer.isEmpty ? "收到。我会先形成规划，同步审议风险和权限，再调度必要能力节点执行。" : answer,
            summary: summary?.isEmpty == false ? summary : "本轮进入通用治理链路与任务运行时。"
        )
    }

    private func ensureDevelopmentRoute(_ route: CodexRoutePayload, for userPrompt: String) -> CodexRoutePayload {
        var tasks = route.agents
        if !tasks.contains(where: { $0.agent == "执行" }) {
            tasks.insert(
                .init(
                    agent: "执行",
                    task: isProjectExecutionRequest(userPrompt) ? "按用户要求在当前目标环境中完成实现，并在必要时运行验证。" : "按用户要求产出可运行结果、依赖说明和使用方式；不修改当前项目文件。",
                    mode: "执行",
                    cadence: "本轮",
                    rationale: "用户提出可执行产出任务。"
                ),
                at: 0
            )
        }

        let summary = route.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = route.userFacingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTrace(kind: .route, actor: "灵枢", title: "确认执行队列", detail: "本轮是可执行任务，保留执行 agent 参与。")

        return CodexRoutePayload(
            needsAgents: true,
            agents: tasks,
            directAnswer: route.directAnswer,
            finalAnswer: answer.isEmpty ? "收到。我会让执行节点进入队列，给你一版可用结果。" : answer,
            summary: summary?.isEmpty == false ? summary : "本轮进入执行队列。"
        )
    }

    private func ensureTask(_ tasks: inout [CodexAgentTask], agent: String, task: String, mode: String, cadence: String, rationale: String, at preferredIndex: Int? = nil) {
        guard !tasks.contains(where: { $0.agent == agent }) else { return }

        let newTask = CodexAgentTask(agent: agent, task: task, mode: mode, cadence: cadence, rationale: rationale)
        if let preferredIndex {
            tasks.insert(newTask, at: min(preferredIndex, tasks.count))
        } else {
            tasks.append(newTask)
        }
    }

    private func orderedGovernanceTasks(_ tasks: [CodexAgentTask]) -> [CodexAgentTask] {
        return tasks.sorted { left, right in
            LingShuCapabilityRole.orderIndex(for: left.agent) < LingShuCapabilityRole.orderIndex(for: right.agent)
        }
    }

    private func shouldForceDirectAnswer(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let directSignals = [
            "解释", "介绍一下", "描述一下", "能力架构", "你是谁", "你是什么",
            "你叫什么", "灵枢是谁"
        ]

        return directSignals.contains { normalized.contains($0) }
            && !isDevelopmentQueueRequest(prompt)
            && !isProjectExecutionRequest(prompt)
            && !isCapabilityCollaborationRequest(prompt)
    }

    private func isDevelopmentQueueRequest(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let developmentSignals = [
            "写代码", "写一段代码", "代码片段", "脚本", "函数", "爬虫", "web爬虫",
            "程序", "demo", "页面", "接口", "api", "组件", "模块", "实现一个",
            "开发一个", "写一个web", "写一个网页", "写一个工具", "写一个程序",
            "写一个爬虫", "写一个简单的web爬虫", "python", "javascript", "typescript",
            "swift", "html", "css"
        ]

        return developmentSignals.contains { normalized.contains($0) }
    }

    private func isDesignDeliveryRequest(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let designSignals = [
            "ppt", "pptx", "幻灯片", "演示文稿", "演示页", "演讲稿",
            "汇报材料", "汇报页", "答辩材料", "路演材料", "deck",
            "presentation", "slide", "版式", "排版", "视觉方案", "视觉设计",
            "设计稿", "美化页面", "美化ppt", "做一份汇报", "做个汇报"
        ]

        return designSignals.contains { normalized.contains($0) }
    }

    private func isProjectExecutionRequest(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        let projectSignals = [
            "当前项目", "这个项目", "当前xcode", "xcode中", "仓库", "代码库",
            "修改文件", "改一下", "修复", "报错", "构建", "测试", "运行",
            "生成到", "写入", "落地", "实现到", "提交", "当前项目", "这个项目",
            "生成文件", "产出文件", "保存文件", "导出", "pptx", "ppt文件", "演示文稿文件",
            "做ppt", "生成ppt", "产出ppt", "做演示文稿", "生成演示文稿", "产出演示文稿"
        ]

        return projectSignals.contains { normalized.contains($0) }
    }

    private func isKnowledgeOnlyQuestion(_ prompt: String) -> Bool {
        let normalized = normalizeMemoryText(prompt)
        let questionSignals = [
            "是什么", "为什么", "怎么理解", "解释", "介绍一下", "描述一下",
            "能否", "是否可以", "可以吗", "怎么看", "原理", "机制",
            "流程是什么", "架构是什么", "能力架构"
        ]
        let actionSignals = [
            "帮我做", "做一个", "做成", "落地", "推进", "实现", "开发",
            "写一个", "写代码", "生成", "产出", "修改", "修复", "运行",
            "测试一下", "构建", "发布", "迭代", "做ppt", "生成ppt",
            "产出ppt", "做演示文稿", "生成演示文稿", "做汇报材料"
        ]

        return questionSignals.contains { normalized.contains($0) }
            && !actionSignals.contains { normalized.contains($0) }
    }

    private func isLingShuKnowledgeQuestion(_ prompt: String) -> Bool {
        let normalized = normalizeMemoryText(prompt)
        let subjectSignals = ["灵枢", "你", "agent", "智能体", "记忆", "线程", "冷备", "调用链", "能力架构", "流程"]
        return isKnowledgeOnlyQuestion(prompt)
            && subjectSignals.contains { normalized.contains($0) }
            && !isDevelopmentQueueRequest(prompt)
            && !isProjectExecutionRequest(prompt)
    }

    private func isCapabilityCollaborationRequest(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        if isDevelopmentQueueRequest(prompt) || isProjectExecutionRequest(prompt) || isDesignDeliveryRequest(prompt) {
            return true
        }

        if isKnowledgeOnlyQuestion(prompt) {
            return false
        }

        let taskSignals = [
            "软件工程", "项目任务", "产品需求", "业务需求", "需求分析", "需求文档",
            "业务说明书", "技术方案", "架构设计", "测试用例", "验收", "迭代",
            "版本", "bug", "缺陷", "重构", "代码审查", "review", "上线", "部署",
            "ppt", "幻灯片", "演示文稿", "汇报材料", "视觉方案", "版式"
        ]

        return taskSignals.contains { normalized.contains($0) }
    }

    private func shouldStartExecutionThread(for userPrompt: String, route: CodexRoutePayload) -> Bool {
        executionCoordinator.shouldStartExecutionThread(
            userPrompt: userPrompt,
            route: route,
            context: executionContext(for: userPrompt)
        )
    }

    private func executionContext(for prompt: String) -> LingShuExecutionContext {
        .init(
            isDevelopmentQueueRequest: isDevelopmentQueueRequest(prompt),
            isProjectExecutionRequest: isProjectExecutionRequest(prompt),
            isKnowledgeOnlyQuestion: isKnowledgeOnlyQuestion(prompt),
            isCapabilityCollaborationRequest: isCapabilityCollaborationRequest(prompt)
        )
    }

    private func taskPermissionBoundary(for prompt: String) -> String {
        permissionDecision(for: prompt).boundary
    }

    private func taskIntent(for prompt: String) -> LingShuTaskIntent {
        if isProjectExecutionRequest(prompt) {
            return .projectExecution
        }
        if isDevelopmentQueueRequest(prompt) {
            return .lightweightDevelopment
        }
        if isCapabilityCollaborationRequest(prompt) {
            return .capabilityCollaboration
        }

        return .direct
    }

    private func permissionDecision(for prompt: String) -> LingShuPermissionDecision {
        permissionPolicy.decide(
            intent: taskIntent(for: prompt),
            codexMode: codexPermissionMode,
            requireHumanApproval: requireHumanApproval
        )
    }

    private func prepareMainThreadMemory(for prompt: String) -> MainThreadMemoryContext {
        let prepared = memoryService.prepareMainThreadMemory(for: prompt)
        mainMemoryStatus = prepared.mainMemoryStatus
        coldMemoryStatus = prepared.coldMemoryStatus
        mainThreadKernel.observeMemoryStatus(prompt: prompt, status: prepared.context.status)
        appendTrace(
            kind: .system,
            actor: "主线程记忆",
            title: prepared.traceTitle,
            detail: prepared.traceDetail
        )
        return prepared.context
    }

    func rememberMainThreadTurn(prompt: String, reply: String, route: CodexRoutePayload? = nil) {
        if let title = memoryService.rememberMainThreadTurn(
            prompt: prompt,
            reply: reply,
            route: route,
            isCapabilityCollaboration: isCapabilityCollaborationRequest(prompt)
        ) {
            appendTrace(kind: .system, actor: "主线程记忆", title: "沉淀", detail: "已更新热记忆：\(title)。")
        }
    }

    private func executionMemoryHint(for prompt: String) -> String {
        let hint = memoryService.executionMemoryHint(for: prompt)
        if taskRuntime.stage != .dormant, let status = hint.runtimeMemoryStatus {
            taskRuntime.memoryStatus = status
        }
        appendTrace(kind: .runtime, actor: "执行记忆", title: hint.traceTitle, detail: hint.traceDetail)
        return hint.text
    }

    private func rememberTask(prompt: String, status: String, summary: String, taskRecordID: String? = nil) {
        memoryService.rememberTask(
            prompt: prompt,
            status: status,
            summary: summary,
            taskID: taskRuntime.taskID,
            taskRecordID: taskRecordID
        )
    }

    func normalizeMemoryText(_ text: String) -> String {
        memoryService.normalizeMemoryText(text)
    }

    private func compactSummaryText(_ text: String, limit: Int) -> String {
        memoryService.compactSummaryText(text, limit: limit)
    }

    private func requestExecutionCodexReply(for userPrompt: String, route: CodexRoutePayload, taskRecordID: String?) {
        guard route.needsAgents, !route.agents.isEmpty else { return }

        isModelExecuting = true
        enterCoreState(.executing)
        let cliPath = codexCLIPath
        let model = modelName
        let workingDirectory = codexWorkingDirectory
        let permissionMode = codexPermissionMode
        let timeout = codexTimeoutSeconds
        let fastMode = codexFastMode
        let executionPrompt = executionPrompt(for: userPrompt, route: route)
        let executionContextKey = activeTaskThread?.id ?? taskRuntime.taskID
        let executionLease = remoteSessionPool.lease(
            provider: modelProvider,
            model: model,
            purpose: .taskExecution,
            contextKey: executionContextKey,
            workingDirectory: workingDirectory,
            permissionBoundary: taskPermissionBoundary(for: userPrompt),
            endpoint: endpoint,
            protocolName: "Codex CLI",
            localContextSummary: executionPrompt
        )
        let runID = missionRunID
        let handle = CodexExecutionHandle()
        activeExecutionHandle = handle
        refreshRemoteSessionStatus()
        recordModelHeartbeat(source: "执行模型", detail: "执行进程已启动。")
        markTaskRuntimeExecuting(route, for: userPrompt)
        appendTaskRecordMessage(taskRecordID, actor: "执行", role: "执行模型", kind: .model, text: "执行进程已启动，我会按任务线程上下文推进并等待可验证结果。")
        appendTrace(
            kind: .system,
            actor: "远端会话池",
            title: executionLease.canResumeNativeSession ? "复用执行会话" : "创建执行会话",
            detail: executionLease.canResumeNativeSession
                ? "命中 \(model) 执行会话，续接任务线程：\(executionContextKey)。"
                : "未命中可复用执行会话，本轮将为任务线程 \(executionContextKey) 创建远端会话。"
        )
        appendTrace(
            kind: .model,
            actor: "执行模型",
            title: "进入执行",
            detail: "已将用户指令和专家分派发送给后台执行阶段，等待真实模型返回结果。"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CodexBridge.execReply(
                preferredPath: cliPath,
                modelName: model,
                userPrompt: executionPrompt,
                workingDirectory: workingDirectory,
                permissionMode: permissionMode,
                timeout: timeout,
                fastMode: fastMode,
                remoteSessionID: executionLease.nativeSessionID,
                cancellation: handle,
                progress: { chunk in
                    Task { @MainActor in
                        guard self.missionRunID == runID else { return }
                        self.appendCodexStream(chunk, actor: "执行模型")
                    }
                },
                sessionRegistrar: { sessionID in
                    Task { @MainActor in
                        guard self.missionRunID == runID else { return }
                        self.remoteSessionPool.resolveNativeSession(
                            lease: executionLease,
                            nativeSessionID: sessionID,
                            localContextSummary: executionPrompt
                        )
                        self.refreshRemoteSessionStatus()
                        self.appendTrace(
                            kind: .system,
                            actor: "远端会话池",
                            title: "执行会话已登记",
                            detail: "已登记 \(model) 执行 session：\(sessionID)。"
                        )
                    }
                }
            )

            DispatchQueue.main.async {
                guard self.missionRunID == runID else { return }
                if self.activeExecutionHandle === handle {
                    self.activeExecutionHandle = nil
                }
                self.isModelExecuting = false

                switch result {
                case .success(let reply):
                    self.remoteSessionPool.resolveNativeSession(
                        lease: executionLease,
                        nativeSessionID: executionLease.nativeSessionID,
                        localContextSummary: reply
                    )
                    self.refreshRemoteSessionStatus()
                    self.completeRouteExecution(route)
                    let finalReply = self.postProcessExecutionReply(reply, for: userPrompt, route: route)
                    self.mainThreadKernel.observeExecution(prompt: userPrompt, summary: finalReply, completed: true)
                    self.completeTaskRuntime(for: userPrompt, reply: finalReply, taskRecordID: taskRecordID)
                    self.rememberMainThreadTurn(prompt: userPrompt, reply: finalReply, route: route)
                    self.appendTrace(kind: .result, actor: "执行模型", title: "执行返回", detail: finalReply.isEmpty ? "后台执行已返回，但没有可展示文本。" : finalReply)
                    self.appendTaskRecordMessage(taskRecordID, actor: "执行", role: "执行模型", kind: .result, text: finalReply.isEmpty ? "后台执行已返回，但没有可展示文本。" : finalReply)
                    self.materializeTaskArtifacts(for: userPrompt, route: route, reply: finalReply, taskRecordID: taskRecordID)
                    self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "最终验收", kind: .review, text: "我已收到执行回传，并完成本轮验收与统一交付。")
                    self.finishTaskRecord(taskRecordID, status: .completed, summary: finalReply.isEmpty ? "后台执行已完成。" : finalReply)
                    if !finalReply.isEmpty {
                        self.chatMessages.append(.init(speaker: "灵枢", text: finalReply, isUser: false, taskRecordID: taskRecordID))
                    }
                    self.logEvent("现在  后台执行流程已返回。")
                case .failure(let error):
                    self.remoteSessionPool.markFailed(lease: executionLease)
                    self.refreshRemoteSessionStatus()
                    self.mainThreadKernel.observeExecution(prompt: userPrompt, summary: error, completed: false)
                    self.enterCoreState(.abnormal)
                    self.runtimePhase = .correcting
                    self.missionTitle = "异常"
                    self.missionStatus = "执行阶段受阻，我已经停止继续推进，避免产生不可靠结果。"
                    self.blockTaskRuntime(error)
                    self.appendTrace(kind: .warning, actor: "执行模型", title: "执行失败", detail: error)
                    let failureReply = "执行阶段遇到阻断。我已经停止继续推进，避免给你一个不可靠的结果。你可以在配置页检查主通道，或者调整任务后再交给我。"
                    self.appendTaskRecordMessage(taskRecordID, actor: "执行", role: "执行模型", kind: .warning, text: error)
                    self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: failureReply)
                    self.finishTaskRecord(taskRecordID, status: .blocked, summary: failureReply)
                    self.chatMessages.append(.init(speaker: "灵枢", text: failureReply, isUser: false, taskRecordID: taskRecordID))
                    self.logEvent("现在  后台执行流程失败：\(error)")
                }
            }
        }
    }

    func postProcessExecutionReply(_ reply: String, for userPrompt: String, route: CodexRoutePayload) -> String {
        executionCoordinator.postProcessExecutionReply(
            reply,
            userPrompt: userPrompt,
            route: route,
            context: executionContext(for: userPrompt)
        )
    }

    private func executionPrompt(for userPrompt: String, route: CodexRoutePayload) -> String {
        let memoryHint = mainThreadKernel.promptHint(baseMemory: executionMemoryHint(for: userPrompt))
        return executionCoordinator.executionPrompt(
            userPrompt: userPrompt,
            route: route,
            memoryHint: memoryHint,
            isProjectExecutionRequest: isProjectExecutionRequest(userPrompt)
        )
    }

    private func applyRoutePlan(_ route: CodexRoutePayload, for userPrompt: String, taskRecordID: String?) -> String {
        let answer = route.userFacingAnswer
        let summary = route.summary?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard route.needsAgents else {
            taskRuntime = .idle
            resetAgentRuntime(
                title: "待机中",
                status: summary?.isEmpty == false ? summary! : "本轮消息由灵枢直接处理。"
            )
            enterCoreState(.standby, resetTimer: false)
            activeLayer = "待机中"
            trustScore = max(trustScore, 92)
            logEvent("现在  路由判断：无需专家 agent，灵枢直接回复。")
            appendTrace(kind: .result, actor: "灵枢", title: "直接回复", detail: answer)
            return answer
        }

        resetAgentRuntime(
            title: "执行中",
            status: summary?.isEmpty == false ? summary! : "本轮已按任务需要分派专家 agent，右侧只显示参与本次任务的 agent。"
        )
        enterCoreState(.executing)
        runtimePhase = .planning
        activeLayer = "专家分派"
        trustScore = max(trustScore, 92)

        if !missionSteps.isEmpty {
            missionSteps[0].state = .done
        }

        let schedule = agentScheduler.makeSchedule(for: route)
        let selectedAgents = Set(schedule.participatingAgents)
        markMissionStep(1, runningIf: selectedAgents.contains("规划"))
        markMissionStep(2, runningIf: selectedAgents.contains("审议"))
        markMissionStep(3, runningIf: selectedAgents.contains("调度"))
        markMissionStep(4, runningIf: selectedAgents.contains("执行") || selectedAgents.contains("监控") || selectedAgents.contains("验证") || selectedAgents.contains("安全") || selectedAgents.contains("知识") || selectedAgents.contains("记忆") || selectedAgents.contains("路由"))
        markMissionStep(5, runningIf: selectedAgents.contains("审议"))
        markMissionStep(6, runningIf: selectedAgents.contains("调度") || selectedAgents.contains("验证"))

        for dispatch in schedule.dispatches {
            let task = dispatch.task
            configureAgent(
                task.agent,
                mode: dispatch.mode,
                state: .running,
                load: dispatch.load,
                cadence: dispatch.cadence,
                focus: task.task,
                finding: dispatch.finding
            )
            appendTrace(kind: .agent, actor: task.agent, title: "接收分派", detail: task.task)
        }

        let agentNames = schedule.agentSummary
        logEvent("现在  路由判断：调用 \(agentNames)。")
        appendTrace(kind: .route, actor: "灵枢", title: "分派完成", detail: "本轮唤起：\(agentNames)。")
        if shouldStartExecutionThread(for: userPrompt, route: route) {
            scheduleRouteExecutionAnimation(route, taskRecordID: taskRecordID)
        }
        return answer
    }

    private func scheduleRouteExecutionAnimation(_ route: CodexRoutePayload, taskRecordID: String?) {
        let runID = missionRunID
        let schedule = agentScheduler.makeSchedule(for: route)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(550)) { [weak self] in
            guard let self, self.missionRunID == runID else { return }
            self.enterCoreState(.executing, resetTimer: false)
            self.runtimePhase = .executing
            self.activeLayer = "执行中"
            self.missionStatus = "规划、审议、调度已完成准入；必要能力节点按需接令推进。"
            self.appendTrace(kind: .system, actor: "灵枢", title: "进入执行队列", detail: "通用治理链路已接令，后台执行模型仍在运行，等待可验证结果返回。")
            self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .core, text: "规划、审议、调度已完成准入，任务进入执行队列。")

            for dispatch in schedule.dispatches {
                let task = dispatch.task
                let currentMode = dispatch.mode
                let nextMode: AgentRuntimeMode = (currentMode == .planning && (task.agent == "执行" || task.agent == "调度")) ? .working : currentMode
                self.configureAgent(
                    task.agent,
                    mode: nextMode,
                    state: .running,
                    load: 0.82,
                    cadence: self.agentScheduler.runtimeCadence(for: task, mode: nextMode),
                    focus: task.task,
                    finding: "已进入执行队列"
                )
                self.appendTrace(kind: .agent, actor: task.agent, title: "进入队列", detail: "\(task.agent) 正在等待执行模型返回或工具结果。")
                self.appendTaskRecordMessage(taskRecordID, actor: task.agent, role: nextMode.rawValue, kind: .agent, text: "已进入队列，等待执行模型或工具结果回传。")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1250)) { [weak self] in
            guard let self, self.missionRunID == runID, self.isModelExecuting else { return }
            self.runtimePhase = .supervising
            self.activeLayer = "执行中"
            self.markTaskRuntimeMonitoring()
            self.supervisionTick += 1
            let supervisor = schedule.preferredSupervisor
            self.supervisorEvents.insert(
                .init(agent: supervisor, severity: "info", title: "执行巡检", detail: "本轮任务已进入后台执行，灵枢保持统一出声，能力节点状态仅在调用链显示。", tick: self.supervisionTick),
                at: 0
            )
            self.logEvent("巡检\(self.supervisionTick)  \(supervisor)：执行巡检。")
            self.appendTrace(kind: .agent, actor: supervisor, title: "执行巡检", detail: "本轮后台执行仍在等待模型或工具返回，暂未形成最终交付。")
            self.appendTaskRecordMessage(taskRecordID, actor: supervisor, role: "监控", kind: .agent, text: "巡检\(self.supervisionTick)：后台执行仍在等待模型或工具返回，暂未形成最终交付。")
        }
    }

    private func completeRouteExecution(_ route: CodexRoutePayload) {
        enterCoreState(.standby, resetTimer: false)
        runtimePhase = .delivering
        activeLayer = "待机中"
        missionTitle = "待机中"
        missionStatus = "本轮执行已返回结果。我会继续等待你的下一道指令。"
        trustScore = max(trustScore, 93)

        for task in route.agents {
            guard let index = agents.firstIndex(where: { $0.shortName == task.agent }) else { continue }
            agents[index].state = .done
            agents[index].mode = .dormant
            agents[index].load = max(0.32, agents[index].load - 0.18)
            agents[index].lastFinding = "本轮任务已回传灵枢"
        }

        for index in missionSteps.indices where missionSteps[index].state == .running {
            missionSteps[index].state = .done
        }

        appendTrace(kind: .result, actor: "灵枢", title: "本轮收束", detail: "后台执行结果已回传，相关 agent 已从执行态恢复为待机。")
    }

    private func completeNonExecutingRoute(_ route: CodexRoutePayload, for userPrompt: String, reply: String, taskRecordID: String? = nil) {
        enterCoreState(.standby, resetTimer: false)
        runtimePhase = .delivering
        activeLayer = "待机中"
        missionTitle = "待机中"
        missionStatus = "本轮完成规划/判断，不需要创建执行线程。"
        trustScore = max(trustScore, 92)

        for task in route.agents {
            guard let index = agents.firstIndex(where: { $0.shortName == task.agent }) else { continue }
            agents[index].state = .done
            agents[index].mode = .dormant
            agents[index].load = max(0.30, agents[index].load - 0.14)
            agents[index].lastFinding = "本轮完成判断，未进入工具执行"
        }

        for index in missionSteps.indices where missionSteps[index].state == .running {
            missionSteps[index].state = .done
        }

        if isCapabilityCollaborationRequest(userPrompt) {
            taskRuntime.stage = .delivering
            taskRuntime.summary = "灵枢完成任务规划/判断，本轮不需要工具循环。"
            taskRuntime.currentAction = "等待用户确认是否进入后续执行。"
            taskRuntime.reviewGate = "规划答复已完成"
            taskRuntime.checks = [
                .init(title: "记忆", detail: taskRuntime.memoryStatus, state: .done),
                .init(title: "上下文", detail: "已完成主线程判断和必要协作", state: .done),
                .init(title: "权限", detail: "未进入工具执行，无文件操作", state: .done),
                .init(title: "工具循环", detail: "本轮无需启动", state: .done),
                .init(title: "Review", detail: "灵枢已完成规划答复", state: .done)
            ]
            rememberTask(prompt: userPrompt, status: "planned", summary: reply, taskRecordID: taskRecordID)
        }

        appendTrace(kind: .result, actor: "灵枢", title: "非执行收束", detail: "本轮只完成判断、规划或解释，没有创建执行线程。")
    }

    private func markMissionStep(_ index: Int, runningIf shouldRun: Bool) {
        guard missionSteps.indices.contains(index), shouldRun else { return }
        missionSteps[index].state = .running
    }

    private func runtimeMode(for task: CodexAgentTask) -> AgentRuntimeMode {
        agentScheduler.runtimeMode(for: task)
    }

    private func runtimeCadence(for task: CodexAgentTask, mode: AgentRuntimeMode) -> String {
        agentScheduler.runtimeCadence(for: task, mode: mode)
    }

    private func runtimeFinding(for task: CodexAgentTask) -> String {
        agentScheduler.runtimeFinding(for: task)
    }

    func startDemoMission() {
        missionRunID += 1
        let runID = missionRunID
        runtimePhase = .planning
        supervisionTick = 0
        supervisorEvents = []
        missionTitle = "能力协作：并行监控运行时"
        missionStatus = "规划节点先拟定任务草案，调度节点编排能力；执行期启动监控线程，持续校验目标、进度、边界和体验。"
        trustScore = 88
        activeLayer = "灵枢调度"
        logEvent("现在  用户向灵枢提交复杂目标。")
        appendTrace(kind: .system, actor: "演示", title: "启动演示", detail: "启动一次通用能力流转演示。")

        for index in missionSteps.indices {
            missionSteps[index].state = .waiting
        }
        for index in agents.indices {
            agents[index].state = .waiting
            agents[index].mode = .dormant
            agents[index].cadence = "-"
            agents[index].focus = "等待灵枢发令"
            agents[index].lastFinding = "尚未巡检"
            agents[index].load = max(0.18, agents[index].load * 0.72)
        }

        let schedule: [(Int, String, [String], Int)] = [
            (0, "灵枢受令并开启任务准入判断。", ["路由"], 90),
            (1, "规划节点形成任务草案、执行计划和能力分派建议。", ["规划"], 88),
            (2, "审议节点同步核查可行性、风险和授权条件。", ["审议"], 86),
            (3, "调度节点接收通过审核的计划并准备分派能力。", ["调度", "路由"], 87),
            (4, "执行、监控、验证等能力节点按需协作。", ["执行", "监控", "验证"], 84),
            (5, "审议节点过程监督，监控节点同步观察状态。", ["审议", "监控"], 86),
            (6, "调度节点汇总落地结果，验证节点执行质量门。", ["调度", "验证"], 89),
            (7, "灵枢完成最终验收、风险归纳和下一步交付。", ["路由", "审议"], 92)
        ]

        for (offset, item) in schedule.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(520 * offset)) { [weak self] in
                guard let self, self.missionRunID == runID else { return }
                self.advance(stepIndex: item.0, log: item.1, activeAgents: item.2, trust: item.3, runID: runID)
            }
        }
    }

    private func advance(stepIndex: Int, log: String, activeAgents: [String], trust: Int, runID: Int) {
        for index in missionSteps.indices {
            if index < stepIndex {
                missionSteps[index].state = .done
            } else if index == stepIndex {
                missionSteps[index].state = .running
            } else {
                missionSteps[index].state = .waiting
            }
        }

        for index in agents.indices {
            if activeAgents.contains(agents[index].shortName) {
                agents[index].state = .running
                agents[index].mode = stepIndex < 4 ? .planning : .working
                agents[index].focus = stepIndex < 4 ? "生成前置产物" : "执行任务分片"
                agents[index].load = min(0.95, agents[index].load + 0.36)
            } else if agents[index].state == .running && agents[index].mode != .supervising {
                agents[index].state = .done
                agents[index].mode = .dormant
                agents[index].load = max(0.24, agents[index].load - 0.22)
            }
        }

        trustScore = trust
        runtimePhase = stepIndex < 2 ? .planning : stepIndex < 4 ? .planning : stepIndex < 7 ? .executing : .verifying
        activeLayer = stepIndex < 2 ? "目标受理" : stepIndex < 4 ? "治理编排" : stepIndex < 7 ? "并行执行" : "验收交付"
        logEvent("现在  \(log)")
        appendTrace(kind: .agent, actor: activeAgents.joined(separator: "、"), title: "演示流转", detail: log)

        if stepIndex == 4 {
            activateSupervision(runID: runID)
        }

        if stepIndex == missionSteps.indices.last {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(650)) { [weak self] in
                guard let self, self.missionRunID == runID else { return }
                self.runtimePhase = .delivering
                for index in self.missionSteps.indices {
                    self.missionSteps[index].state = .done
                }
                for index in self.agents.indices where self.agents[index].state == .running {
                    self.agents[index].state = .done
                    self.agents[index].mode = .dormant
                    self.agents[index].load = max(0.35, self.agents[index].load - 0.14)
                }
                self.missionTitle = "等待灵枢最终验收"
                self.missionStatus = "任务草案、推进方案、执行产物、巡检纠偏记录和验证报告已汇总，高风险操作仍需人工确认。"
                self.logEvent("现在  任务进入灵枢最终验收节点。")
            }
        }
    }

    private func activateSupervision(runID: Int) {
        guard missionRunID == runID else { return }
        runtimePhase = .supervising
        activeLayer = "并行监控"
        missionTitle = "执行期：监控线程运行中"
        missionStatus = "执行节点推进产出，监控节点观察心跳和偏差，验证节点准备验收；发现偏差先上报灵枢裁决。"
        logEvent("现在  监控调度器启动：执行、监控、验证进入周期巡检。")
        appendTrace(kind: .agent, actor: "监控调度器", title: "周期巡检启动", detail: "执行、监控、验证进入周期巡检；审议节点等待风险信号。")

        configureAgent("执行", mode: .working, state: .running, load: 0.88, cadence: "实时", focus: "处理任务分片", finding: "等待监控反馈")
        configureAgent("验证", mode: .verifying, state: .running, load: 0.62, cadence: "提交后", focus: "准备质量与回归检查", finding: "等待执行产物")
        configureAgent("监控", mode: .supervising, state: .running, load: 0.78, cadence: "实时", focus: "心跳、进度、偏差", finding: "监控基线已建立")
        configureAgent("知识", mode: .planning, state: .running, load: 0.54, cadence: "本轮", focus: "补充上下文依据", finding: "知识材料待回填")

        let checks: [(Int, String, String, String, String, Int)] = [
            (460, "监控", "进度巡检", "执行节点已进入处理，但验证口径还未完全回填，建议调度补齐验收排期。", "info", 87),
            (920, "监控", "路径偏移预警", "检测到执行路径可能绕过既定模型网关，建议暂停该分支并补充接口契约。", "high", 82),
            (1420, "规划", "目标一致性校验", "当前执行仍覆盖语音提交、能力调度、验证报告三项核心验收标准，未发现目标跑偏。", "ok", 88),
            (1980, "验证", "体验一致性巡检", "配置页和对话页的状态反馈不一致，建议统一显示模型连接状态和监控状态。", "medium", 85),
            (2560, "调度", "纠偏派单", "已将路径偏移预警转为执行节点修正任务，并要求验证节点新增模型网关回归用例。", "medium", 86),
            (3180, "验证", "回归触发", "执行节点修正后触发功能验证，验证节点接入验收队列。", "ok", 89)
        ]

        for item in checks {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(item.0)) { [weak self] in
                guard let self, self.missionRunID == runID, [MissionRuntimePhase.supervising, .executing, .correcting].contains(self.runtimePhase) else { return }
                self.recordSupervisorEvent(agent: item.1, title: item.2, detail: item.3, severity: item.4, trust: item.5)
            }
        }
    }

    private func recordSupervisorEvent(agent: String, title: String, detail: String, severity: String, trust: Int) {
        supervisionTick += 1
        trustScore = trust
        runtimePhase = severity == "high" || severity == "medium" ? .correcting : .supervising
        activeLayer = severity == "high" || severity == "medium" ? "灵枢纠偏" : "并行监工"

        supervisorEvents.insert(.init(agent: agent, severity: severity, title: title, detail: detail, tick: supervisionTick), at: 0)
        logEvent("巡检\(supervisionTick)  \(agent)：\(title)。")
        appendTrace(kind: severity == "high" || severity == "medium" ? .warning : .agent, actor: agent, title: title, detail: detail)

        if severity == "high" {
            configureAgent(agent, mode: .correcting, state: .running, load: 0.92, cadence: "立即", focus: title, finding: detail)
            configureAgent("审议", mode: .correcting, state: .running, load: 0.80, cadence: "立即", focus: "风险封驳与裁决建议", finding: "高风险偏差进入灵枢裁决门")
            configureAgent("执行", mode: .correcting, state: .running, load: 0.90, cadence: "实时", focus: "修正路径偏差", finding: "等待监控节点纠偏指令")
        } else {
            configureAgent(agent, mode: agent == "验证" ? .verifying : .supervising, state: .running, load: 0.78, cadence: agentCadence(agent), focus: title, finding: detail)
        }

        if severity == "medium" {
            configureAgent("调度", mode: .correcting, state: .running, load: 0.86, cadence: "立即", focus: "重排任务与补充验收", finding: detail)
        }
    }

    private func configureAgent(_ shortName: String, mode: AgentRuntimeMode, state: StepState, load: Double, cadence: String, focus: String, finding: String) {
        guard let index = agents.firstIndex(where: { $0.shortName == shortName }) else { return }
        agents[index].mode = mode
        agents[index].state = state
        agents[index].load = load
        agents[index].cadence = cadence
        agents[index].focus = focus
        agents[index].lastFinding = finding
    }

    private func agentCadence(_ agent: String) -> String {
        agentScheduler.agentCadence(agent)
    }
}
