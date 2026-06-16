import AppKit
import Combine
import SwiftUI

private enum LingShuPreferenceKeys {
    static let requiresVoiceWakeWord = "lingshu.voice.requiresWakeWord"
    static let voiceWakeWord = "lingshu.voice.wakeWord"
    static let modelProvider = "lingshu.model.provider"
    static let modelName = "lingshu.model.name"
    static let modelEndpoint = "lingshu.model.endpoint"
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
    case meeting   // 会议对方发言(系统音频→ASR)→ 灵枢应答经虚拟麦回到会议
    case plugin(String)

    var displayName: String {
        switch self {
        case .typed:
            return "文字输入"
        case .voice:
            return "语音转写"
        case .meeting:
            return "会议发言"
        case .plugin(let name):
            return name
        }
    }
}

@MainActor
final class LingShuState: ObservableObject {
    @Published var selectedSurface: AppSurface = .chat
    @Published var selectedNav: NavItem = .command
    @Published var prompt: String = ""
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
    // 模型选择持久化(写进配置,跨重启保留所选大脑——灵枢可灵活更换大模型,选了 DeepSeek 重启后仍是 DeepSeek)。
    @Published var modelProvider = UserDefaults.standard.string(forKey: LingShuPreferenceKeys.modelProvider) ?? ModelProviderPreset.minimaxOfficial.name {
        didSet { UserDefaults.standard.set(modelProvider, forKey: LingShuPreferenceKeys.modelProvider) }
    }
    @Published var modelName = UserDefaults.standard.string(forKey: LingShuPreferenceKeys.modelName) ?? ModelProviderPreset.minimaxOfficial.defaultModels[0] {
        didSet { UserDefaults.standard.set(modelName, forKey: LingShuPreferenceKeys.modelName) }
    }
    @Published var endpoint = UserDefaults.standard.string(forKey: LingShuPreferenceKeys.modelEndpoint) ?? ModelProviderPreset.minimaxOfficial.endpoint {
        didSet { UserDefaults.standard.set(endpoint, forKey: LingShuPreferenceKeys.modelEndpoint) }
    }
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
    // 计算机直接操作四肢(截屏/点击/键入)总开关:默认关,授权语义=用户显式开启 + 系统辅助功能授权(计划 §9)。
    // 独立运行「完整授权」档自动视为开启(完整电脑控制)。
    @Published var computerControlEnabled = UserDefaults.standard.bool(forKey: "lingshu.computerControlEnabled") {
        didSet { UserDefaults.standard.set(computerControlEnabled, forKey: "lingshu.computerControlEnabled") }
    }
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
    /// 任务窗口的用户反馈:recordID → 👍true/👎false(持久 UserDefaults)。👎 的任务不进 dreaming 固化样本。
    @Published var taskRecordFeedback: [String: Bool] = [:]
    @Published var archivedTaskExecutionRecords: [LingShuTaskExecutionRecord] = []
    @Published var isExecutionConsoleExpanded = true
    @Published var autonomousRun: LingShuAutonomousRunSnapshot = .idle
    // 独立运行默认「完整授权」:独立运行=授予完整电脑控制权,推进中不再要授权(唯删/改系统级敏感文件除外)。
    @Published var autonomousPermissionLevel: LingShuAutonomousPermissionLevel = .full
    // 独立运行专门输入框草稿(目标指令);与对话主输入框 `prompt` 解耦,空目标禁止启动(计划 §1)。
    @Published var autonomousObjectiveDraft: String = ""
    // 独立运行启动时从上传附件抽取的上下文(prepare 时捕获、kickoff 时折入);非 @Published,仅供执行流读取。
    var autonomousAttachmentContext: String = ""
    // 后台守候(条件满足即自动续跑):@Published 供 UI 展示;Task 句柄非 @Published,供取消。
    @Published var backgroundWatches: [LingShuBackgroundWatch] = []
    var backgroundWatchTasks: [String: Task<Void, Never>] = [:]
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
    /// 专家档案库（内置 + 用户 ~/Library/Application Support/LingShu/Skills/*.md 技能）；
    /// 协议化可插拔，用户技能触发词命中时优先。
    let expertProfileRegistry: any LingShuExpertProfileProviding = LingShuCompositeExpertRegistry()
    /// 定时触发服务（提醒/例行任务），分钟级检查，本机 JSON 持久化。
    let scheduledTriggers = LingShuScheduledTriggerService()
    /// MCP 连接器注册表：接外部 MCP server 暴露的工具进协同管线（可插拔）。
    let connectorRegistry = LingShuConnectorRegistry()
    /// 本机工具执行器（读写文件/列目录/抓网页/跑命令）；协议化可替换沙箱实现。
    let toolExecutor: any LingShuToolExecuting = LingShuLocalToolExecutor()
    let dialogueAcknowledgement = LingShuDialogueAcknowledgement()
    /// 统一的待确认问题编排中心：自主运行非交互裁决等据此判断。见 LingShuClarificationCenter。
    let clarificationCenter = LingShuClarificationCenter()
    private let taskRuntimeCoordinator = LingShuTaskRuntimeCoordinator()
    private let modelGateway = LingShuModelGateway()
    let remoteModelClient = LingShuRemoteModelClient()
    /// 主会话派生的并行子会话经此编排(隔离上下文 + 有界并发 + 统一账本 + 续接)。
    let agentOrchestrator = LingShuAgentOrchestrator(maxConcurrent: 3)
    /// 常驻主 agent 会话(对话连续性);懒构造,见 LingShuState+AgentBackbone。
    var mainAgentSessionHolder: LingShuAgentSession?
    /// 编排器子会话 id → 任务执行记录 id(让每条并行子任务成为列表里独立任务号)。
    var agentSubTaskRecords: [String: String] = [:]
    /// 主线程分诊「派发」的任务:记录 id → 它在对话里的加载气泡 id(完成时回填这条气泡而非另起一条)。
    /// Stage 2 多任务真隔离:每条派发任务有自己的气泡 + 独立 session,互不串。
    var dispatchedTaskBubbles: [String: UUID] = [:]
    /// 主会话当前回合的任务记录 id;工具桥据此把产出文件登记到正确记录。
    var currentAgentTurnRecordID: String?
    /// 当前 agent 主回合的 Task(供语音通话"真指令打断"取消在飞模型调用)。
    var activeAgentTurnTask: Task<Void, Never>?
    /// 编排器事件 sink 是否已注入(幂等)。
    var agentEventSinkInstalled = false
    /// 网络可达性监控(断网重连自动续跑);懒启动(首次有 agent 活动时),见 LingShuState+AgentOrchestration。
    var connectivityMonitor: LingShuConnectivityMonitor?
    /// 主会话回合因网络中断而挂起时,保存续跑所需上下文(气泡/记录/原始请求/起算时刻);重连后从中断处续跑。
    var suspendedMainTurn: (bubbleID: UUID, recordID: String?, prompt: String, startedAt: Date)?
    /// 独立运行因网络中断而挂起时的任务记录 id;重连后 continueLoop 续跑(会话在 autonomousSessionHolder)。
    var suspendedAutonomousRecordID: String?
    /// 网络重试循环(断网后主动按退避重试 + 在主对话框可见地展示重试次数/下次间隔),见 LingShuState+NetworkRetry。
    var networkRetryTask: Task<Void, Never>?
    /// 主对话框里那条「网络异常·重试中」状态气泡 id(原地更新次数/间隔,不刷屏)。
    var networkRetryBubbleID: UUID?
    /// 当前重试次数;NWPathMonitor 检测到链路恢复时置 `networkRetryKick` 让重试循环立即再试(重置退避)。
    var networkRetryAttempt = 0
    var networkRetryKick = false
    /// 最近完成的可交付产出物(内存镜像,供"运行起来/继续/改一下"接得上 + 注入主线程&派发任务上下文)。
    /// 落盘走增量持久化 `deliverableStore`(WAL+快照),跨 app 重启可恢复。见 LingShuState+Deliverables。
    var recentDeliverables: [LingShuDeliverable] = []
    /// 增量记忆持久化(WAL 追加写 + 阈值/定时压缩;Phase 5)。
    let deliverableStore = LingShuIncrementalStore<LingShuDeliverable>(directory: LingShuState.memoryStoreDirectory, name: "deliverables")
    /// 定时压缩(checkpoint)定时器。
    var memoryCompactionTimer: Timer?

    /// 能力通道校验状态(channelKey → 校验结果):中枢/视觉/视频/听/语音各通道"是否实测校验通过"。
    /// channelKey 形如 `brain:DeepSeek` / `vision:datanet` / `tts:dataNetSpeakerTTS` / `asr:local`。
    /// 持久化到 UserDefaults;各模态选择器 + 子线程切换只列"已配置且校验通过"的通道。见 LingShuState+ModelChannels。
    @Published var channelValidations: [String: LingShuChannelValidation] = LingShuState.loadChannelValidations() {
        didSet { LingShuState.saveChannelValidations(channelValidations) }
    }
    /// 正在校验中的 channelKey(UI 转圈)。
    @Published var validatingChannels: Set<String> = []
    /// TTS 通道用户自定义显示名(descriptor.id → 自定义名)。写死的 displayName 不准时(如"男声"其实是女声)用户可改,持久化。
    @Published var ttsChannelNames: [String: String] = (UserDefaults.standard.dictionary(forKey: "lingshu.ttsChannelNames") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(ttsChannelNames, forKey: "lingshu.ttsChannelNames") }
    }

    static func loadChannelValidations() -> [String: LingShuChannelValidation] {
        guard let data = UserDefaults.standard.data(forKey: "lingshu.channelValidations"),
              let decoded = try? JSONDecoder().decode([String: LingShuChannelValidation].self, from: data) else { return [:] }
        return decoded
    }
    static func saveChannelValidations(_ v: [String: LingShuChannelValidation]) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: "lingshu.channelValidations") }
    }

    /// 增量记忆落盘目录(Application Support/LingShu/memory)。
    static var memoryStoreDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LingShu/memory", isDirectory: true)
    }
    /// 上次 dreaming 离线固化时间(节流,见 LingShuState+Dreaming);nil=本次会话还没固化过。
    var lastDreamConsolidationAt: Date?
    // 自主运行执行(统一 agent 循环驱动):在飞 Task / 本轮记录 id / 执行会话 / ask_user 待答问题。
    var autonomousRunTask: Task<Void, Never>?
    var autonomousRunRecordID: String?
    var autonomousSessionHolder: LingShuAgentSession?
    var autonomousPendingQuestion: String?
    private let permissionPolicy = LingShuPermissionPolicy()
    private let externalAgentRegistry = LingShuExternalAgentRegistry()
    private let externalAgentGateway = LingShuExternalAgentGateway()
    let credentialStore = LingShuCredentialStore()
    let chatHistoryStore = LingShuChatHistoryStore()
    let remoteSessionPool = LingShuRemoteSessionPool()
    let remoteConnectionPolicy = LingShuRemoteConnectionPolicy()
    let taskExecutionJournal = LingShuTaskExecutionJournal()
    let engineeringArtifactService = LingShuEngineeringArtifactService()
    let autonomousEnvironmentProbe = LingShuAutonomousEnvironmentProbe()
    let autonomousRunbookPlanner = LingShuAutonomousRunbookPlanner()
    let autonomousSelfCheckRunner = LingShuAutonomousSelfCheckRunner()
    var missionRunID = 0
    /// 本次会话启动时间：情境上下文用它计算连续使用时长。
    let sessionStartedAt = Date()
    private var thinkingStartedAt: Date?
    private var executionStartedAt: Date?
    var lastModelHeartbeatAt: Date?
    private var activeThinkingMessageID: UUID?
    /// 流式思考增量的逐消息累积缓冲（仅加载中气泡使用，定稿即清）；
    /// 消费逻辑在 LingShuState+Streaming.swift。
    var thinkingPreviewBuffers: [UUID: String] = [:]
    /// 流式分句早读：根视图在语音输出开启时注册；流式正文每攒满一句立即播报。
    var streamingSentenceSpeaker: ((String) -> Void)?
    /// 根视图注入：掐断当前 TTS 朗读。新一轮开始时调,避免上一条回复音频盖到新轮(音频/文字 desync)。
    var interruptSpeechOutput: (() -> Void)?
    /// 每条流式消息已播报到的字符偏移（分句早读去重，定稿即清）。
    var spokenStreamOffsets: [UUID: Int] = [:]
    private var activeRouteHandle: CodexExecutionHandle?
    private var activeExecutionHandle: CodexExecutionHandle?
    var activeAPITask: Task<Void, Never>?
    var isMainRemoteProbeInFlight = false
    var mainRemoteProbeRunID = 0
    var activeHealthProbeHandle: CodexExecutionHandle?
    var mainRemoteLastProbeAt: Date?
    var mainRemoteLastSuccessAt: Date?
    var mainRemoteConsecutiveFailures = 0
    var mainRemoteLastFailureReason = ""
    var mainRemoteLastDiagnosticLog = ""
    /// 待用户授权的系统命令（高风险动作人工确认弹窗）：非空即弹中文授权框。
    @Published var pendingShellApproval: LingShuPendingShellApproval?
    /// 用户在本次会话里选了「完全授权」后置真：后续 run_command 不再逐条弹窗。
    var sessionShellAlwaysAllowed = false
    /// 自发现高风险 skill 脚本的隔离表(运行期):materialize 时按 skillID 隔离清单填入,
    /// key=脚本绝对路径、value=skillID + 风险点;命令引用它时强制弹审批(即便已"完全授权")。
    var quarantinedScriptPaths: [String: (skillID: String, notes: [String])] = [:]
    var isRestoringChatHistory = false
    var chatHistoryPersistTask: Task<Void, Never>?
    var persistedConversationDigest = ""
    /// 由根视图注入的语音管理器(供会议对话控制器经 MCP/UI 驱动 TTS / 读播放状态)。
    weak var voiceManager: VoiceIOManager?
    /// 会议端到端对话控制器:系统音频→ASR→agent→TTS→虚拟麦。`@Published` 供 UI 显示是否在会中。
    @Published var meetingConversation = LingShuMeetingConversationController()
    /// 文件预览中枢(灵枢的"眼睛+手"):大脑用四肢工具打开 PPT/PDF/Word/Excel 并翻页/滚动(演示/阅读)。
    let previewController = LingShuPreviewController()
    /// 由根视图注入：返回当前实时态势感知上下文（无有效信号时返回空串）。
    var livePerceptionContextProvider: (() -> String)?
    /// 对话发生时按需刷新云端场景理解（根视图注册到感知网关）。
    var perceptionSceneRefreshTrigger: (() -> Void)?

    init() {
        restoreChatHistory()
        // 非交互裁决策略：自主运行中且非观察模式时，待确认问题自动按安全默认定夺，
        // 不阻塞无人值守执行（任务续接死锁那一类的根治）。其余场景照常逐题询问用户。
        clarificationCenter.isNonInteractive = { [weak self] in
            guard let self else { return false }
            return self.autonomousRun.phase == .running && self.autonomousRun.permissionLevel != .observe
        }
        if let preset = selectedModelPreset,
           let storedKey = credentialStore.apiKey(forProvider: preset.id) {
            apiKey = storedKey
        }
        let report = mainThreadKernel.bootReport
        mainThreadSessionStatus = report.statusText
        mainThreadHeartbeatText = report.heartbeatText
        mainMemoryStatus = report.memoryStatus
        taskExecutionRecords = taskExecutionJournal.loadRecords()
        taskRecordFeedback = (UserDefaults.standard.dictionary(forKey: "lingshu.taskFeedback") as? [String: Bool]) ?? [:]
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

    /// 当前主模型是否原生多模态。true → 图片内联进消息直喂模型（KIMI K2.6 类）；
    /// false → 图片走云视觉解析成文字再注入（MiniMax M3 类，零留存）。换模型只动这个判断。
    var usesNativeMultimodal: Bool {
        selectedModelPreset?.supportsNativeMultimodal ?? false
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

    func blockTaskRuntime(_ error: String) {
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
        fireScheduledTriggersIfDue(now: now)
        if let heartbeat = mainThreadKernel.heartbeat(now: now) {
            mainThreadHeartbeatText = heartbeat.displayText
            if mainThreadSessionStatus != "主线程常驻运行中" {
                mainThreadSessionStatus = "主线程常驻运行中"
            }
        }
        refreshRemoteSessionStatus()
        tickMainRemoteConnectionGuard(now: now)
        tickAutonomousRun(now: now)

        if hasActiveModelCall, let lastModelHeartbeatAt {
            modelHeartbeatIdleSeconds = max(0, Int(now.timeIntervalSince(lastModelHeartbeatAt)))
        }

        if coreState == .thinking, let startedAt = thinkingStartedAt {
            thinkingElapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
            updateThinkingBubble()

            // 只做"还在干、没卡死"的安心提示;不再到点强行中断——agent 循环自己在模型层重试自愈,
            // 单次调用超时不等于整轮失败(灵枢是自主 AGI,不是一超时就放弃的业务系统)。用户可随时按停止接管。
            if thinkingElapsedSeconds == 45 {
                missionStatus = "主通道响应偏慢，我还在推进，必要时会自动重试。"
            } else if thinkingElapsedSeconds == 90 {
                missionStatus = "仍在推进中。我不会把未完成的判断伪装成结果。"
            }
        }

        if coreState == .executing, let startedAt = executionStartedAt, isModelExecuting || runtimePhase != .idle {
            executionElapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        }
    }

    func cancelActiveCodexCalls() {
        activeRouteHandle?.cancel()
        activeExecutionHandle?.cancel()
        activeHealthProbeHandle?.cancel()
        activeAPITask?.cancel()
        activeRouteHandle = nil
        activeExecutionHandle = nil
        activeHealthProbeHandle = nil
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

        // 若正卡在系统命令授权弹窗上：按拒绝收口，解除挂起的工具协程，别让弹窗悬着。
        if pendingShellApproval != nil {
            resolveShellApproval(.deny)
        }

        let messageID = activeThinkingMessageID
        cancelActiveCodexCalls()
        // 统一 agent 循环的在飞回合 + 自主运行也要真正取消(否则停止只是改了状态,后台还在跑)。
        activeAgentTurnTask?.cancel()
        activeAgentTurnTask = nil
        autonomousRunTask?.cancel()
        autonomousRunTask = nil
        isModelReplying = false
        isModelExecuting = false
        missionTitle = "待机中"

        let response = "本轮调用已停止。"
        appendTrace(kind: .warning, actor: "用户", title: "停止调用", detail: "用户中止当前进程，灵枢已撤销在飞的 agent 回合。")
        blockTaskRuntime("用户手动停止了本轮能力运行时。")
        resetAgentRuntime(title: "待机中", status: response)
        enterCoreState(.standby, resetTimer: false)
        activeLayer = "待机中"

        // 收口所有还在转圈的加载气泡(agent 路不设 activeThinkingMessageID,得按 isLoading 找)。
        var closedAny = false
        for index in chatMessages.indices where chatMessages[index].isLoading && !chatMessages[index].isUser {
            chatMessages[index].text = chatMessages[index].text.isEmpty ? response : chatMessages[index].text
            chatMessages[index].isLoading = false
            closedAny = true
        }
        if let messageID, let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].text = response
            chatMessages[index].isLoading = false
        } else if !closedAny {
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

    /// 记忆提示 + 实时态势感知 + 情境上下文的统一组装：见 LingShuState+Context.swift。
    /// currentReplyAdapter 在 LingShuState+Streaming.swift 定义（按主通道选回复适配器）。

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
        guard let token = dataNetGatewayToken(), let url = URL(string: gateway.endpoint) else {
            return nil
        }
        return LingShuCloudPerceptionClient(baseEndpoint: url, token: token)
    }

    /// 数据网关 token 的统一解析(VL/感知与 TTS 共用同一口径,避免"TTS 能用、VL 却说没配"的不一致):
    /// ① 主通道就是网关 → 用当前 apiKey;② 凭据库(灵枢配置数据库,加密落盘,用户写入的权威来源);
    /// ③ 随包 RuntimeConfig 兜底。任一非空即用。
    func dataNetGatewayToken() -> String? {
        let gateway = ModelProviderPreset.dataNetGateway
        let currentKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedModelPreset?.id == gateway.id, !currentKey.isEmpty { return currentKey }
        if let stored = credentialStore.apiKey(forProvider: gateway.id),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        if let bundled = LingShuBundledRuntimeConfig().token(forProvider: gateway.id),
           !bundled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundled
        }
        return nil
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

        // 换脑即时生效 + 记忆延续:重建常驻会话(主/自主),下次回合用新模型重新构造 adapter,
        // 并经 seededDistilledMemory 重新 seed(蒸馏对话记忆 + 最近产出物)——换的是大脑,记忆接着用。
        mainAgentSessionHolder = nil
        autonomousSessionHolder = nil

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
        let text = prompt
        prompt = ""
        return submitTextWithAttachments(text, source: .typed)
    }

    /// 提交一条指令并**带上待发附件**(把附件正文折入提示 + 清空托盘)。
    /// UI sendPrompt 与 MCP `lingshu_send_prompt` 共用——修"MCP 发送时附件没一并带出"的 bug。
    @discardableResult
    func submitTextWithAttachments(_ text: String, source: LingShuDialogueInputSource) -> String {
        let attachmentContext = attachmentContextBlock()
        let userText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachmentContext.isEmpty else {
            return submitTextInput(userText, source: source)
        }
        // 有附件时：用户消息原文照常入库展示，但发给模型的提示前置附件正文上下文。
        let combined = userText.isEmpty
            ? "\(attachmentContext)\n\n请按上述文件落地交付。"
            : "\(attachmentContext)\n\n用户指令：\n\(userText)"
        // 把随发的附件名挂到这条用户消息上(气泡里展示),再清空托盘。
        let names = pendingAttachments.map(\.filename)
        let displayText = userText.isEmpty ? "已上传 \(names.count) 个文件" : userText
        chatMessages.append(.init(speaker: "你", text: displayText, isUser: true, attachmentNames: names))
        clearAttachments()
        return submitTextInput(combined, source: source, appendUserMessage: false)
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

        let taskRecordID = existingTaskRecordID ?? createTaskExecutionRecord(for: trimmedPrompt)
        if appendUserMessage {
            chatMessages.append(.init(speaker: "你", text: trimmedPrompt, isUser: true))
        }
        prompt = ""

        // 已有回合在跑时不清在飞轨迹（agent 循环里严格串行接续）；否则重置轨迹。
        if !bypassActiveGate && hasActiveModelCall {
            appendTrace(kind: .runtime, actor: "任务队列", title: "并发接令", detail: "已有回合在跑，本轮在 agent 循环里串行接续。")
        } else {
            resetExecutionTrace(for: trimmedPrompt)
        }
        appendTrace(kind: .system, actor: source.displayName, title: "文本入队", detail: "\(source.displayName) 已落成文本，进入灵枢 agent 循环。")
        // 用户开口的瞬间按需刷新场景理解（异步，不阻塞本轮；本地解析路由不出网）。
        perceptionSceneRefreshTrigger?()

        // 自主运行卡在 ask_user 提问上时，本轮输入即为答案：回填续跑（优先于一切常规分流）。
        if let answerAck = handleAutonomousAnswerIfNeeded(prompt: trimmedPrompt, taskRecordID: taskRecordID) {
            return answerAck
        }

        if let autonomousResponse = handleAutonomousRunCommandIfNeeded(
            prompt: trimmedPrompt,
            taskRecordID: taskRecordID
        ) {
            return autonomousResponse
        }

        // 续接/追问(已有记录)→ 直接主回合,不分诊(继续这件事,不重新派发)。
        if existingTaskRecordID != nil {
            return runMainAgentTurn(prompt: trimmedPrompt, taskRecordID: taskRecordID)
        }

        // 新顶层输入:主线程**先分诊**(Stage 2 多任务真隔离)——
        //   直答(对话/问答)→ 留主 session(runMainAgentTurn,对话连续);
        //   任务(要执行/落盘/多步)→ 派发**独立隔离 session 并行跑**(dispatchIsolatedTask,不串主上下文)。
        // 分诊是一次轻量模型判定(保守:失败/对话一律留主线程,不误派)。异步,故即时无文案,真回复经气泡给出。
        Task { @MainActor [weak self] in
            guard let self else { return }
            let triage = await self.classifyDispatch(trimmedPrompt)
            if triage.dispatch {
                self.dispatchIsolatedTask(prompt: trimmedPrompt, taskRecordID: taskRecordID, goal: triage.goal)
            } else {
                _ = self.runMainAgentTurn(prompt: trimmedPrompt, taskRecordID: taskRecordID)
            }
        }
        return ""
    }

    func refreshCodexAuthStatusIfNeeded() {
        guard usesCodexAuth, codexAuthStatus == "未检查" else { return }
        refreshCodexAuthStatus()
    }

    func forceMainRemoteHealthProbe() {
        performMainRemoteHealthProbe(reason: "手动探活", force: true)
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


    func rememberMainThreadTurn(prompt: String, reply: String, route: CodexRoutePayload? = nil) {
        if let title = memoryService.rememberMainThreadTurn(
            prompt: prompt,
            reply: reply,
            route: route,
            isCapabilityCollaboration: false
        ) {
            appendTrace(kind: .system, actor: "主线程记忆", title: "沉淀", detail: "已更新热记忆：\(title)。")
        }
    }

    func normalizeMemoryText(_ text: String) -> String {
        memoryService.normalizeMemoryText(text)
    }

    func compactSummaryText(_ text: String, limit: Int) -> String {
        memoryService.compactSummaryText(text, limit: limit)
    }

}
