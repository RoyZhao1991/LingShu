import AppKit
import Combine
import SwiftUI

private enum LingShuPreferenceKeys {
    static let requiresVoiceWakeWord = "lingshu.voice.requiresWakeWord"
    static let voiceWakeWord = "lingshu.voice.wakeWord"
    static let modelProvider = "lingshu.model.provider"
    static let modelName = "lingshu.model.name"
    static let modelEndpoint = "lingshu.model.endpoint"
    static let asrLocalMode = "lingshu.perception.asrLocalMode"
    static let ttsLocalMode = "lingshu.perception.ttsLocalMode"
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
    @Published var missionStatus = "我在。能力池已注册，随时待命，等你开口。"
    // trustScore（顶栏/核心区 TRUST）现为**真实计算的就绪度**，不再写死——见 LingShuState+RuntimeStatus.swift。
    /// 「大脑」评分(顶栏 HUD,替代 TRUST):自主完成任务 +1 / 触发兜底 −1 / 换脑归零。见 LingShuState+BrainScore.swift。
    /// 只读语义靠约定(只有 LingShuState+BrainScore 的 setBrainScore 改它);跨文件扩展需要可写,故不用 private(set)。
    @Published var brainScore: LingShuBrainScore = LingShuState.loadBrainScore()
    /// 内置脑力测试:运行中标志 + 结果(非 nil → 弹窗展示)。见 LingShuState+BrainBenchmark.swift。
    @Published var isRunningBrainBenchmark = false
    @Published var brainBenchmarkResult: LingShuBrainBenchmarkResult?
    /// 跨脑对比:每颗测过的脑存一份快照(最新),弹窗并排比各档水位。
    @Published var brainBenchmarkHistory: [LingShuBrainBenchmarkSnapshot] = LingShuState.loadBenchmarkHistory()
    @Published var coreState: LingShuCoreState = .standby
    /// LOOP 内环节(理解/规划/执行/验收),实时显示给用户(本体浮窗 + 状态栏),免得干等。见 LingShuState+LoopPhase。
    @Published var loopPhase: LingShuLoopPhase = .idle
    /// **界面语言**(国际化:中/英)——切它整个界面/状态/本体动态切语言,并同步语音子系统(ASR/TTS/回复语言)。
    /// 持久化共用 "lingshu.voiceLanguage" 一个键(语言全局统一,不分 UI/语音两套)。见 LingShuState+Localization。
    @Published var language: LingShuVoiceLanguage = VoiceIOManager.persistedVoiceLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: "lingshu.voiceLanguage")
            voiceManager?.voiceLanguage = language
            // 外接设备蓝牙广播名随语言切换(中文「灵枢」/ 英文「Nous」)。
            externalSensory.setBluetoothLocalName(appName)
        }
    }
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
    /// 听觉·本地模式：开=强制本机识别（Apple Speech，实时麦克风兜底永远可用）；关=偏好数据网关云端 ASR。
    /// 本机有兜底方案的能力（耳/口）给用户一个显式开关，确认到底走不走本机，而不是悄悄自动降级。
    @Published var asrLocalModeEnabled = LingShuPreferenceDefaults.bool(forKey: LingShuPreferenceKeys.asrLocalMode, defaultValue: true) {
        didSet {
            UserDefaults.standard.set(asrLocalModeEnabled, forKey: LingShuPreferenceKeys.asrLocalMode)
            applyASRLocalMode()
        }
    }
    /// 语音口·本地模式：开=强制 macOS 系统语音；关=偏好数据网关情绪语音（不可用时仍兜底本机）。
    @Published var ttsLocalModeEnabled = LingShuPreferenceDefaults.bool(forKey: LingShuPreferenceKeys.ttsLocalMode, defaultValue: false) {
        didSet {
            UserDefaults.standard.set(ttsLocalModeEnabled, forKey: LingShuPreferenceKeys.ttsLocalMode)
            applyTTSLocalMode()
        }
    }
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
    /// 「进入聆听模式」会话:已进入(响过提示音)为 true;静默超时后失效、下次再进入会重新响。
    /// 非会议=声音触发进入,会议=唤醒词触发进入(见 LingShuPerceptionActions)。
    var voiceListeningArmed = false
    var lastVoiceActivityAt = Date.distantPast
    /// 「我在听」聆听窗口时长（秒）：喊唤醒词/开口进入后，窗口内没识别到有效内容就回退待机
    /// （状态机：我在听 →(无有效内容)→ 待机），下次唤醒/开口重新响铃。供状态机推导与 tick 复位共用。
    let voiceListeningWindowSeconds: TimeInterval = 6
    var lastSpokenMessageID: UUID?
    /// 最近经 `speak` 念出口的话(环形缓冲,封顶 40 条)——供脚本核验演示文字稿对得上幻灯片。
    @Published var recentSpokenLines: [String] = []
    @Published var temperature = 0.2
    @Published var contextBudget = 128000.0
    @Published var localStreamingDialogueEnabled = true
    @Published var enableLocalAudit = true
    @Published var requireHumanApproval = true
    /// **开发阶段全权(2026-06-21,用户拍板)**:系统授权门(run_command 审批)在开发期**直接放行、不每次弹框**=灵枢拿到最高权限;
    /// 发布后回到人工授权。**DEBUG 构建默认开**(开发期=`build-app.sh debug`),**Release 默认关**(发布版人工授权);
    /// 可经 UserDefaults `lingshu.devFullAccess` 覆盖 + `setDevelopmentPhaseFullAccess` 切换。
    /// **唯一仍拦的红线**:未审第三方 skill 脚本(供应链 quarantine,不是灵枢自身动作,`未审代码不静默执行`只增不减);
    /// 物理执行器每次确认是另一道硬件安全门、不在此门内。状态见 `lingshu_status.developmentFullAccess`。
    @Published var developmentPhaseFullAccess: Bool = LingShuState.loadDevFullAccessDefault()
    // 计算机直接操作四肢(截屏/点击/键入)总开关:默认关,授权语义=用户显式开启 + 系统辅助功能授权(计划 §9)。
    // 独立运行「完整授权」档自动视为开启(完整电脑控制)。
    @Published var computerControlEnabled = UserDefaults.standard.bool(forKey: "lingshu.computerControlEnabled") {
        didSet {
            UserDefaults.standard.set(computerControlEnabled, forKey: "lingshu.computerControlEnabled")
            // 打开开关即向系统申请权限(辅助功能 + 屏幕录制),立刻弹系统授权框——不等首次动作。
            if computerControlEnabled, !oldValue { requestComputerControlPermissions() }
        }
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
    /// 通用中枢世界模型:汇总用户、任务、agent、设备、服务、感知与验收事件。
    /// 当前先作为基础设施接线层,后续 UI/执行器统一读写它,避免各模块互相直连。
    @Published var worldModel: LingShuWorldModel = LingShuState.loadWorldModelSnapshot()
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
    /// 灵枢身体表现层：由大脑/工具临时下发的表现指令；为空时由实时状态自动推导。
    @Published var digitalHumanDirective: LingShuDigitalHumanDirective?

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
    /// **任务线串行(用户定调 2026-06-23「1+1=2 双线」)**:同时只 1 个任务在执行,其余进可删除队列区(信息池)。
    /// 与问答线(主会话)独立并行。任务卡住(待用户/阻断)会释放槽位让队列晋级(见编排器 .blocked),不阻问答。
    let agentOrchestrator = LingShuAgentOrchestrator(maxConcurrent: 1)
    /// 常驻主 agent 会话(对话连续性);懒构造,见 LingShuState+AgentBackbone。
    /// 核心循环变体开关(新旧循环热切换):`.classic`=经典连续循环 / `.nested`=嵌套分阶段验收循环。
    /// 持久化到 UserDefaults(跨重启保留所选引擎);经 `setAgentLoopVariant` 切换(默认常量/MCP 调试口)。
    var agentLoopVariant: LingShuAgentLoopVariant = UserDefaults.standard.string(forKey: "lingshu.agentLoopVariant").flatMap(LingShuAgentLoopVariant.init(rawValue:)) ?? .classic
    var mainAgentSessionHolder: (any LingShuAgentSessioning)?
    /// 编排器子会话 id → 任务执行记录 id(让每条并行子任务成为列表里独立任务号)。
    var agentSubTaskRecords: [String: String] = [:]
    // 注:P1 GoalSpec 不再用内存字典 —— 作为 typed 字段持久化进 LingShuTaskExecutionRecord.goalSpec(跨重启),经 goalSpec(for:) 读。
    /// 主线程分诊「派发」的任务:记录 id → 它在对话里的加载气泡 id(完成时回填这条气泡而非另起一条)。
    /// Stage 2 多任务真隔离:每条派发任务有自己的气泡 + 独立 session,互不串。
    var dispatchedTaskBubbles: [String: UUID] = [:]
    /// 派发任务的「评审绑定」:记录 id →(maker 引擎 / checker 引擎 / 是否异源)。创建子线程时解析并标注,验收时据 checker 复核。
    var taskReviewBindings: [String: LingShuReviewBinding] = [:]
    /// **派发队列区**(用户定调):主界面支持 3 并发,多出来的进**可见队列区等待**(不直接进主窗口/不派发);
    /// 有空位时自动晋级派发;晋级前可在队列区删除。见 LingShuState+DispatchQueue。
    @Published var queuedDispatchTasks: [LingShuQueuedDispatchTask] = []
    /// **问答线(主会话)可删等待队列**(用户定调 2026-06-23「1+1=2 双线」):问答串行,**只1条在执行**,其余**等待中可删**。
    /// 与任务线独立并行(1任务+1问答可同时跑;任一卡住不阻另一条)。pending=已排队的答复气泡;executing=正在跑的那条(不可删)。
    @Published var pendingChatTurnIDs: [UUID] = []
    @Published var executingChatTurnID: UUID?
    /// 已删除的问答答复气泡:对应 turn 轮到执行点时**跳过**(不真跑、不进会话上下文)。
    var cancelledChatTurnIDs: Set<UUID> = []
    /// 主问答队列的执行载荷。`pendingChatTurnIDs` 只保存 UI 气泡 id,这里保存真正要跑的 prompt/record 边界。
    /// 这样 activeAgentTurnTask 永远只代表**当前队首 worker**,不会再把“最新排队项”误当“正在执行项”取消。
    var pendingMainTurns: [UUID: LingShuPendingMainTurn] = [:]
    /// 模块变体注册表(P6+ 无界自进化)改版计数:注册/切换/回退后 bump,驱动变体管理面板刷新(注册表本身存 UserDefaults 按需读)。
    @Published var moduleVariantsRevision = 0
    /// **自我进化(P6)总开关**:默认**关闭**(自进化属高风险能力,需主人显式开启 + 风险确认)。
    /// 关 → 不挖反复弱点/不提改进提案/不采纳,零行为;开 → P6 自检弱点并提**待批**提案(采纳仍逐条人批、可一键回退)。
    /// 持久化 `lingshu.selfEvolution`。改 via `setSelfEvolutionEnabled`。见 [[pluggable-self-evolution-m0-m1]][[skill-self-evolution]]。
    @Published var selfEvolutionEnabled: Bool = (UserDefaults.standard.object(forKey: "lingshu.selfEvolution") as? Bool ?? false)
    /// 某条**派发的隔离任务**正卡在 ask_user 等用户回答(它问了主题/要信息):上下文感知分诊把它标成
    /// "⏳正等你回答",让分诊器认出用户的答复(哪怕隔了几条)并续到那条隔离会话。见 buildTriageContext。
    var blockedDispatchedRecordID: String?
    /// **主会话**刚用 ask_user/ask_form 问了用户、正等回答的那条记录 id。下一条用户消息应**续到主会话这条任务**
    /// (把答复接回去),而不是被重新分诊成一个**新任务**(根治"答复被当成新请求→丢了原目标",如把"待办内容"误当"设个6点提醒")。
    var pendingMainQuestionRecordID: String?
    /// 主会话当前回合的任务记录 id;工具桥据此把产出文件登记到正确记录。
    var currentAgentTurnRecordID: String?
    /// 当前 agent 主回合的 Task(供语音通话"真指令打断"取消在飞模型调用)。
    var activeAgentTurnTask: Task<Void, Never>?
    /// `activeAgentTurnTask` 对应的气泡 id。取消后旧 worker 可能晚返回;用它防止旧 worker 清掉新 worker。
    var activeAgentTurnBubbleID: UUID?
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
    /// 记忆 v2 知识图谱(吸收 Obsidian:原子笔记 + 别名归一 + 双链 + 园丁自维护)。懒加载,从 vault 恢复;
    /// 召回 additive 进 recall_memory,dreaming 调 tend 自维护。详见 Sources/Memory/。
    lazy var knowledgeGraph = LingShuKnowledgeGraph()
    /// 本轮工作记忆:用户明确说“记住/记录”的短事实先本地保存,给随后的“刚才我说的X”零延迟召回。
    /// 长期沉淀仍会同步写知识图谱;这里负责主线程低延迟、不依赖远端模型的工作记忆闭环。
    var localWorkingFacts: [String] = []
    /// 本机文件知识索引(第一刀:文件/文档/代码)。全本地、零上传(on-device 向量),按 opt-in 目录索引,供 recall_local 检索增强答案。
    lazy var localKnowledgeIndex = LingShuFileKnowledgeIndex()
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
    /// 各能力通道(口/眼/耳,中枢走 preset)的用户配置(channelKey → 名/端点/模型),持久化。
    /// 写死名不准(如"男声"实为女声)或要改端点/模型时用户自己配;密钥仍走 credentialStore(按 channelKey)。
    @Published var channelConfigs: [String: ModelChannelConfig] = LingShuState.loadChannelConfigs() {
        didSet { LingShuState.saveChannelConfigs(channelConfigs) }
    }
    static func loadChannelConfigs() -> [String: ModelChannelConfig] {
        guard let data = UserDefaults.standard.data(forKey: "lingshu.channelConfigs"),
              let decoded = try? JSONDecoder().decode([String: ModelChannelConfig].self, from: data) else { return [:] }
        return decoded
    }
    static func saveChannelConfigs(_ v: [String: ModelChannelConfig]) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: "lingshu.channelConfigs") }
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
    var autonomousSessionHolder: (any LingShuAgentSessioning)?
    /// 在岗答复的**流式气泡** id:在岗答复(对话)边生成边逐字上屏(与主界面同款),收尾时由 finishAutonomousRun 定稿。
    /// nil = 本回合非流式(开场招呼/目标驱动独立运行,仍走末尾一次性回灌)。
    var standingStreamingBubbleID: UUID?
    var autonomousPendingQuestion: String?
    /// 互动中派后台的子任务**完成后的待汇报队列**:在互动中完成则攒这里(不打断),择机捎带/待机时主动汇报。
    var pendingSubtaskReports: [String] = []
    /// 汇报防抖:最近一次有子任务完成入队的时刻 / 本批待汇报最早入队时刻——用于"接连完成的合并一起报",别零散刷屏。
    var lastSubtaskReportEnqueuedAt = Date.distantPast
    var firstPendingReportAt: Date?
    /// 复杂多交互任务(演示/讲解/会议/答疑)直接上岗时,把"上岗后第一件要做的事"暂存到这——
    /// 让上岗的开场白直接变成"做这件交互任务",而不是先寒暄。用完即清。详见 goLiveForInteractiveTask。
    var pendingStandingKickoff: String?
    /// run_steps 批量执行中被主人插话/打断的一次性信号:置位后批量循环在下一步边界停下、交还大脑处理插话。
    /// 见 LingShuState+BatchExecution(consumeBatchInterrupt)与各 interject 路径。
    var batchInterruptRequested = false
    // 周期感知循环(模块2):常驻灵枢在岗时定时感知屏幕+系统声音 → 注入/唤醒。详见 LingShuState+AutonomousPerception。
    /// 自主反应「武装」开关:开 = 环境事件(如有人开始说话)可唤醒大脑自主处理;关 = 只保持感知 digest 新鲜,不擅自行动(安全默认)。
    @Published var autonomousAutoReactArmed = UserDefaults.standard.bool(forKey: "lingshu.autoReactArmed") {
        didSet { UserDefaults.standard.set(autonomousAutoReactArmed, forKey: "lingshu.autoReactArmed") }
    }
    /// 最新一份周期感知态势(屏幕一句话描述 + 音频活动),供接管态遮罩显示、命令前置注入。
    /// 仅由 LingShuState+AutonomousPerception 写入(跨文件扩展,故不能用 private(set))。
    @Published var perceptionDigest = ""
    let perceptionCadenceConfig = LingShuPerceptionCadenceConfig.default
    var perceptionAudioDetector = LingShuAudioActivityDetector()
    var lastPerceptionTickAt = Date.distantPast
    var lastPerceptionVLAt = Date.distantPast
    var lastPerceptionWakeAt = Date.distantPast
    var lastScreenSignature = ""
    var perceptionVLTask: Task<Void, Never>?
    /// 周期感知是否由本对象启动了系统音频采集(会议未占用时);停感知时只关自己启的,不误关会议的。
    var perceptionOwnsAudioCapture = false
    /// 在岗「听系统声音」是否在跑(系统音频→会议 ASR→感知链 ambient 通道,纯听不应答)。上岗自动开、离岗关。
    var standingAmbientASRActive = false
    /// 在岗期间把麦克风切到 SenseVoice(独立引擎,腾出 SFSpeech 给系统声音)前的原识别提供方,离岗还原。
    var standingPrevMicProvider: LingShuVoiceTranscriptionProviderDescriptor?
    // 会议纪要(在岗时:检测进入会议→分段累积转写→离会自动生成纪要落档+推送)。详见 LingShuState+MeetingMinutes。
    var meetingDetectionState = LingShuMeetingDetectionState()
    var meetingMinutesActive = false
    var meetingMinutesSegments: [LingShuMeetingMinuteSegment] = []
    var meetingMinutesStartedAt: Date?
    var meetingMinutesRotationTask: Task<Void, Never>?
    /// 自主运行/在岗期间持有的 App Nap 抑制令牌:防止灵枢被切到后台(它正操作别的 app=自己必然在后台)时
    /// 被系统 App Nap 暂停心跳定时器 → 周期感知/推进全停。在岗/运行时持有,暂停/停止时释放。
    var autonomousActivityToken: NSObjectProtocol?
    /// 周期感知的**专用驱动 Task**:不依赖 UI 的 Timer.publish(它在窗口被遮挡/后台时会被暂停),
    /// 用协作线程池的 Task.sleep 自驱 + beginActivity 抑制 App Nap → 灵枢在后台操作别的 app 时感知仍持续。
    var autonomousPerceptionDriverTask: Task<Void, Never>?
    /// 在岗/自主运行时开关麦克风语音收听(=极简模式那套:听→ASR→思考→回应)。由根视图注入(它持 voice+perceptionGateway)。
    var startStandingVoiceListening: (() -> Void)?
    var stopStandingVoiceListening: (() -> Void)?
    var perceptionLatestAudioState: LingShuAudioActivityState?
    /// 锁存「起音」事件:心跳每秒采音,但 planner 只在 due 拍消费——免得在非 due 拍丢掉起音。
    var perceptionAudioOnsetLatched = false
    /// 周期感知最近一拍的诊断(为什么 VL 跑没跑),供 MCP/状态观测。**非 @Published**——只被 MCP 按需读,
    /// 不绑定任何视图,避免每拍(4s)无谓触发 SwiftUI 重渲(尤其别在 TTS 播放时给主线程添负担)。
    var perceptionDebugLine = ""
    var perceptionTickSeq = 0
    private let permissionPolicy = LingShuPermissionPolicy()
    private let externalAgentRegistry = LingShuExternalAgentRegistry()
    private let externalAgentGateway = LingShuExternalAgentGateway()
    let credentialStore = LingShuCredentialStore()
    let chatHistoryStore = LingShuChatHistoryStore()
    let remoteSessionPool = LingShuRemoteSessionPool()
    let remoteConnectionPolicy = LingShuRemoteConnectionPolicy()
    let taskExecutionJournal = LingShuTaskExecutionJournal()
    /// 能力主动探测注册表:把"图谱未命中"升级为"主动探测/推断/留下证据",第二阶段接入能力图谱。
    let capabilityProbeRegistry = LingShuCapabilityProbeRegistry()
    let engineeringArtifactService = LingShuEngineeringArtifactService()
    let autonomousEnvironmentProbe = LingShuAutonomousEnvironmentProbe()
    /// 外接设备感知中枢（手机通知/日历…独立模块汇聚成标准输入）。详见 LingShuState+ExternalSensory。
    let externalSensory = LingShuExternalSensoryHub.makeDefault()
    /// 统一外设中枢(一个已连接外设列表:mDNS + 串口/USB/蓝牙/电源/传感器/组件 + 本机可控;分类分组由大脑判)。面板见 LingShuPeripheralsView。
    let peripheralHub = LingShuPeripheralHub()
    /// 感知链:各感官独立采集 → ~1s 高频融合进一条有界缓冲;大脑按时间窗瞬时拉取(感知节奏与大脑节奏解耦)。
    let perceptionChain = LingShuPerceptionChain()
    /// 根视图注入:返回此刻摄像头/麦克风等"活感官"的采样(感知网关持有,故经闭包取)。
    var liveSenseSampler: (() -> [LingShuPerceptionSample])?
    /// 感知链高频采样驱动 Task(~1s)。
    var perceptionChainDriverTask: Task<Void, Never>?
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
    /// 经托管模式确认转入(goLiveForInteractiveTask)→ 本体**立即出现**(跳过 2.5s 入场仪式,免演示开场那段没本体)。见根视图 onChange。
    var enteringViaManagedHandoff = false
    /// 用户在本次会话里选了「完全授权」后置真：后续 run_command 不再逐条弹窗。
    var sessionShellAlwaysAllowed = false
    /// 自发现高风险 skill 脚本的隔离表(运行期):materialize 时按 skillID 隔离清单填入,
    /// key=脚本绝对路径、value=skillID + 风险点;命令引用它时强制弹审批(即便已"完全授权")。
    var quarantinedScriptPaths: [String: (skillID: String, notes: [String])] = [:]
    /// ask_choice 待解析的点选(气泡 id → 续接器):大脑用 ask_choice 弹可点选项时,handler 挂起在此等用户点击;
    /// 用户在选项卡片上点选 → selectRouteChoice 唤醒它、把所选项喂回在飞的循环(不另起输入)。
    var pendingChoiceResolvers: [UUID: (String) -> Void] = [:]
    /// 新阻塞协议下的 ask_choice:循环已 `.blocked` 释放任务槽,这里只记住卡片属于哪条主任务;
    /// 点选后用 `session.resume` 回填原工具调用。
    var pendingChoiceContexts: [UUID: LingShuPendingHumanInputContext] = [:]
    /// ask_form 待提交的多项确认表单(气泡 id → 续接器):大脑用 ask_form 弹多字段表单时挂起在此,
    /// 用户填完点「提交」→ submitFormAnswers 唤醒它、把各字段答案喂回在飞的循环。
    var pendingFormResolvers: [UUID: ([String: String]) -> Void] = [:]
    /// 新阻塞协议下的 ask_form:循环已 `.blocked` 释放任务槽,表单提交后 resume 原工具调用。
    var pendingFormContexts: [UUID: LingShuPendingHumanInputContext] = [:]
    /// P3 沙箱:apply_skill 物化过的 skill 脚本路径 → 该 skill 声明的权限(P1)。run_command 跑到这些脚本时,
    /// 按声明权限(+工作目录写,让生成器能产出)经 sandbox-exec 关进受限子进程,而非无沙箱裸跑。无声明=最小权限。
    var materializedSkillScripts: [String: LingShuPluginPermissions] = [:]
    var isRestoringChatHistory = false
    var chatHistoryPersistTask: Task<Void, Never>?
    var persistedConversationDigest = ""
    /// 由根视图注入的语音管理器(供会议对话控制器经 MCP/UI 驱动 TTS / 读播放状态)。
    weak var voiceManager: VoiceIOManager?
    /// 会议端到端对话控制器:系统音频→ASR→agent→TTS→虚拟麦。`@Published` 供 UI 显示是否在会中。
    @Published var meetingConversation = LingShuMeetingConversationController()
    /// 文件预览中枢(灵枢的"眼睛+手"):大脑用四肢工具打开 PPT/PDF/Word/Excel 并翻页/滚动(演示/阅读)。
    let previewController = LingShuPreviewController()
    /// 「演示与答疑」插件的演示编排引擎(脚本/答疑/续演/多文档队列);钩子由 installPresentationHooks 装配。
    let presentationController = LingShuPresentationController()
    /// 在飞的演示播放任务(后台照稿念;用户输入经 handlePresentationInputIfNeeded 拦成答疑)。
    var presentationPlaybackTask: Task<Void, Never>?
    /// 内置多 tab 浏览器:大脑用 browser_* 四肢上网/做网页自动化测试(打开URL/多tab/JS执行/滚动/全屏)。
    let browserController = LingShuBrowserController()
    /// 由根视图注入：返回当前实时态势感知上下文（无有效信号时返回空串）。
    var livePerceptionContextProvider: (() -> String)?
    /// 对话发生时按需刷新云端场景理解（根视图注册到感知网关）。
    var perceptionSceneRefreshTrigger: (() -> Void)?

    init() {
        installGeneralHubInfrastructure()
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
        // 启动清理:后台任务不跨重启存活,所以加载到的"执行中"记录都是上次没收尾的僵尸——标为"已暂停",
        // 别让任务列表挂一堆永远"执行中"(实测困惑)。状态本身不触发自动续跑(那靠内存里的暂停集合,重启已空)。
        var hadZombie = false
        for i in taskExecutionRecords.indices where taskExecutionRecords[i].status == .running {
            taskExecutionRecords[i].status = .suspended
            hadZombie = true
        }
        if hadZombie { persistTaskExecutionRecords() }
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
        // P6+ 无界自进化:确保所有可进化槽位都有基线变体(回退有处可去、变体面板一上来就列得全)。幂等。
        ensureAllModuleBaselines()
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

        recordWorldEvent(kind: .system, source: actor, summary: "\(title):\(cleanedDetail)", payload: [
            "traceKind": kind.rawValue,
            "isStream": isStream ? "true" : "false"
        ])
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

        // LOOP 相位起止:待机=收(idle);思考/执行开场先显「理解中」,随后由工具调用细化到规划/执行/验收。
        switch newState {
        case .standby, .abnormal: loopPhase = .idle
        case .thinking, .executing: if loopPhase == .idle { loopPhase = .understanding }
        }

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
        reapStaleLoadingBubbles(now: now)   // 自愈:收口"卡死的孤儿加载气泡"(无在飞驱动却永久转圈,实测过 W3 卡"理解需求 437s")
        if let heartbeat = mainThreadKernel.heartbeat(now: now) {
            mainThreadHeartbeatText = heartbeat.displayText
            if mainThreadSessionStatus != "主线程常驻运行中" {
                mainThreadSessionStatus = "主线程常驻运行中"
            }
        }
        refreshRemoteSessionStatus()
        tickMainRemoteConnectionGuard(now: now)
        tickAutonomousRun(now: now)
        // 周期感知循环(模块2)由专用驱动 Task 驱动(见 beginAutonomousActivity),**不挂这里的 UI 心跳**——
        // UI Timer 在窗口遮挡/后台会被暂停,且在主线程跑 AX 会饿死音频。专用 Task 走后台算 AX + 抑制 App Nap。
        expireDigitalHumanDirectiveIfNeeded(now: now)

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
        let currentChatTurnID = executingChatTurnID
        let currentRecordID = currentChatTurnID.flatMap { id in
            chatMessages.first(where: { $0.id == id })?.taskRecordID ?? pendingMainTurns[id]?.taskRecordID
        }
        let hadActiveWork = hasActiveModelCall
            || activeAgentTurnTask != nil
            || autonomousRunTask != nil
            || pendingShellApproval != nil
        // 「演示与答疑」在跑 → **先**彻底停掉(置停止位 + 掐音频),必须在下面 interruptSpeechOutput 之前,
        // 否则音频被掐后 play 循环会抢着念下一页(竞态)→ 用户感知"取消后还在播"。
        stopPresentationIfActive()
        // 停止时若正在全屏演示:一并关预览 + 设防重弹窗(停止演示=别再让大脑下一步把它弹回来,与关窗硬中断一致)。
        if previewController.slideshow {
            previewController.suppressAutoReopenUntil = Date().addingTimeInterval(5)
            _ = previewController.close()
        }
        batchInterruptRequested = true
        interruptSpeechOutput?()
        if pendingShellApproval != nil {
            resolveShellApproval(.deny)
        }
        cancelActiveCodexCalls()
        if let currentChatTurnID { cancelledChatTurnIDs.insert(currentChatTurnID) }
        activeAgentTurnTask?.cancel()
        activeAgentTurnTask = nil
        activeAgentTurnBubbleID = nil
        autonomousRunTask?.cancel()
        autonomousRunTask = nil
        isModelReplying = false
        isModelExecuting = false
        // **先停派发的隔离子任务**:它们不计入 hasActiveModelCall,旧逻辑(下面的 guard)根本停不掉——
        // 跑飞/卡死的 PPT 等隔离任务夺不回。cancelAllRunning 取消其驱动 Task,.failed 事件把记录收尾。
        let orchestrator = agentOrchestrator
        Task { @MainActor [weak self] in
            let n = await orchestrator.cancelAllRunning()
            guard let self, n > 0 else { return }
            self.appendTrace(kind: .warning, actor: "用户", title: "停止派发任务", detail: "已取消 \(n) 条正在跑的隔离子任务。")
            if !self.hasActiveModelCall { self.missionTitle = "待机中"; self.enterCoreState(.standby, resetTimer: false) }
        }
        guard hadActiveWork else {
            reapStaleLoadingBubbles(force: true)   // 即便已无在飞调用,手动停止也要清掉卡住的孤儿加载气泡(否则永久转圈)
            return
        }

        let messageID = activeThinkingMessageID
        missionTitle = "待机中"

        let response = "本轮调用已停止。"
        appendTrace(kind: .warning, actor: "用户", title: "停止调用", detail: "用户中止当前进程，灵枢已撤销在飞的 agent 回合。")
        blockTaskRuntime("用户手动停止了本轮能力运行时。")
        resetAgentRuntime(title: "待机中", status: response)
        enterCoreState(.standby, resetTimer: false)
        activeLayer = "待机中"

        // 只收口**当前执行中的主问答气泡**。等待队列里的 loading 气泡仍表示“排队中”,
        // 不能因为用户停止当前任务就被误写成“已停止”(一问一答串台/误杀根因)。
        var closedAny = false
        if let currentChatTurnID, let index = chatMessages.firstIndex(where: { $0.id == currentChatTurnID }) {
            chatMessages[index].text = response
            chatMessages[index].isLoading = false
            closedAny = true
        } else if let messageID, let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            chatMessages[index].text = response
            chatMessages[index].isLoading = false
            closedAny = true
        } else if !closedAny {
            chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false))
        }
        appendTaskRecordMessage(currentRecordID, actor: "用户", role: "停止", kind: .warning, text: response)
        finishTaskRecord(currentRecordID, status: .failed, summary: "用户已停止本轮调用。")

        logEvent("现在  用户停止了本轮模型调用。")
        scheduleNextMainTurnIfIdle()
    }

    /// **物理硬中断**(用户要求 2026-06-19):关闭灵枢任一窗口(尤其演示窗)= 明确"我不要了" → 彻底中断当前流程,
    /// 别再续跑、别再自己把窗弹回来。比脆弱的语音打断可靠——演示中喊"灵枢"常因 ASR 没把唤醒词识别进来、被 busy 门控丢弃。
    /// 设防重弹抑制窗:挡住"关窗瞬间批量还有一步在飞又把预览拉起"的竞态(根治"手动退出后它又自己把 PPT 弹出来")。
    func abortActiveFlow(reason: String) {
        lingShuControlLog("flow/abort: \(reason)")
        stopPresentationIfActive()               // 「演示与答疑」在跑 → 先彻底停(置停止位 + 掐音频,避免掐后抢念下一页)
        previewController.suppressAutoReopenUntil = Date().addingTimeInterval(5)  // 5s 内拒绝任何 open/进全屏
        batchInterruptRequested = true          // run_steps 批量在下一步边界停,别再翻页/讲
        interruptSpeechOutput?()                 // 立刻掐断当前 TTS 朗读
        _ = previewController.close()            // 关预览(幂等)
        appendTrace(kind: .warning, actor: "用户", title: "关窗中断流程", detail: reason)
        cancelCurrentCall()                      // 停主回合 + 自主运行 + 派发隔离任务 + 收口加载气泡
    }

    /// **物理软暂停**(用户要求 2026-06-19):演示/占屏执行中检测到用户动鼠标/键盘 → 立刻停自动推进+朗读(可恢复)。
    /// 不硬取消回合,停在当前页等用户「继续演示」或下一步指示。判定可靠的前提:演示期间灵枢不产生键鼠事件(翻页走内部),
    /// 故全屏演示中任何输入=用户在夺回控制(计算机控制类占屏因灵枢自身会动鼠标,不走此暂停)。
    func pauseActiveFlow(reason: String) {
        lingShuControlLog("flow/pause: \(reason)")
        if presentationController.isActive { presentationController.requestPauseForQA() }   // 「演示与答疑」一并暂停(掐音频+不再狂翻)
        batchInterruptRequested = true     // 停 run_steps 自动翻页/连续执行
        interruptSpeechOutput?()            // 停当前朗读
        missionStatus = "已暂停(检测到你在手动操作)。点「继续演示」接着讲,或直接下新指令。"
        appendTrace(kind: .system, actor: "用户", title: "动鼠标→暂停演示", detail: reason)
    }

    /// 自愈:收口"卡住的孤儿加载气泡"。
    /// 根因(实测 2026-06-19,W3 卡"理解需求 437s"):`runMainAgentTurn` 创建的加载气泡靠其 Task 体内 finalize 收口;
    /// 若该回合被取消/串行等待上一轮而其 Task 没跑到 finalize,且 `cancelCurrentCall` 在 `!hasActiveModelCall` 时提前返回
    /// 跳过清扫 → 气泡永久 loading。这里周期性兜底:无任何在飞回合/自主运行/派发任务驱动它、又转圈超时的加载气泡,自动收口。
    /// - force=true(手动停止):立即收口所有非用户、非"正被派发任务驱动"的加载气泡(不等超时)。
    func reapStaleLoadingBubbles(now: Date = Date(), force: Bool = false) {
        let staleSeconds: TimeInterval = 150
        let liveDispatchBubbleIDs = Set(dispatchedTaskBubbles.values)   // 派发任务还在跑→其气泡合法,别动(由编排器事件收口)
        // 非强制时:有在飞模型调用或自主运行在跑,说明有合法回合可能正驱动加载气泡,整体不收割(避免误伤进行中)。
        if !force, hasActiveModelCall || autonomousRunTask != nil { return }
        var changed = false
        for index in chatMessages.indices where chatMessages[index].isLoading && !chatMessages[index].isUser {
            let msg = chatMessages[index]
            if liveDispatchBubbleIDs.contains(msg.id) { continue }
            if !force, now.timeIntervalSince(msg.createdAt) <= staleSeconds { continue }   // 还没卡够久,再等等
            chatMessages[index].isLoading = false
            if chatMessages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chatMessages[index].text = "（上一轮交互已中断，我已收起等待状态。）"
            }
            changed = true
        }
        if changed, !hasActiveModelCall, autonomousRunTask == nil, missionTitle != "待机中" {
            missionTitle = "待机中"
        }
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
        var detail = "本轮消耗 \(tokens) tokens（网关计量）。"
        if let cached = reply.cachedTokens, cached > 0 {
            let prompt = reply.promptTokens ?? 0
            detail += " 前缀缓存命中 \(cached)" + (prompt > 0 ? "/\(prompt)" : "") + " 输入 token（按缓存价计费，省钱）。"
        }
        appendTrace(kind: .system, actor: "用量", title: stage, detail: detail)
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

        resetBrainScoreForCurrentBrain()   // 换大模型 → 大脑评分归零(评分只属于某一颗脑)

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
        // 演示中语音=barge-in:**先暂停演示循环**(requestPauseForQA 含掐音频+置停止位)再走下游,
        // 保证"先暂停、后掐音频"的顺序——否则先掐音频会让循环以为念完、抢翻下一页(实测翻页残留根因)。
        if presentationController.isActive { presentationController.requestPauseForQA() }
        return submitTextInput(text, source: .voice)
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
        // 「演示与答疑」进行时:用户开口=实时答疑(**主线程线性**,保真人交互感),拦下来处理,不走常规分诊/派发。
        if appendUserMessage, handlePresentationInputIfNeeded(trimmedPrompt) { return "" }
        // 「演示文档」请求:确定性路由到 present_documents 插件(实测模型会习惯性绕开新插件,故硬路由保证用上)。
        if appendUserMessage, handlePresentationStartIfNeeded(trimmedPrompt) { return "" }
        cancelMainRemoteHealthProbe(reason: "探活让路", detail: "收到用户指令，已停止后台探活，把主通道让给本轮任务。")

        // 记录**按需建**(不再在最顶 eager 建):被续答/在岗/答复等早返回接管的轮次用各自的记录,
        // 否则会在任务列表里留一条空壳记录(实测:答"做什么主题"时多出一条空的"介绍你自己的能力·执行中")。
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
        recordWorldEvent(kind: .userInput, source: source.displayName, summary: trimmedPrompt, relatedEntityIDs: ["agent:lingshu"])
        // 用户开口的瞬间按需刷新场景理解（异步，不阻塞本轮；本地解析路由不出网）。
        perceptionSceneRefreshTrigger?()
        let deterministicRoutingPrompt = Self.visibleUserInstructionForDeterministicRouting(from: trimmedPrompt)

        // 弱脑确定性闭环:稳定本体事实/本机时间日期这类问题不需要远端强脑。
        // 仍然创建任务记录、落执行记录、沉淀记忆,避免网关抖动把低风险直答挂起。
        if existingTaskRecordID == nil,
           pendingMainQuestionRecordID == nil,
           let localAnswer = LingShuLocalIntentResolver.answer(for: deterministicRoutingPrompt) {
            let recordID = createTaskExecutionRecord(for: trimmedPrompt)
            bindGoalSpec(LingShuGoalSpec(objective: deterministicRoutingPrompt, kind: .question), to: recordID)
            appendTaskRecordMessage(recordID, actor: "弱脑", role: "本地直答", kind: .core, text: "命中本机确定性问答,无需远端模型。")
            appendTaskRecordMessage(recordID, actor: "灵枢", role: "答复", kind: .result, text: localAnswer)
            chatMessages.append(.init(speaker: "灵枢", text: localAnswer, isUser: false, taskRecordID: recordID))
            appendTrace(kind: .result, actor: "弱脑", title: "本地直答", detail: String(localAnswer.prefix(80)))
            finishTaskRecord(recordID, status: .answered, summary: localAnswer)
            rememberMainThreadTurn(prompt: deterministicRoutingPrompt, reply: localAnswer)
            return localAnswer
        }
        if existingTaskRecordID == nil,
           pendingMainQuestionRecordID == nil,
           let localAnswer = localWorkingMemoryAnswer(for: deterministicRoutingPrompt) {
            let recordID = createTaskExecutionRecord(for: trimmedPrompt)
            bindGoalSpec(LingShuGoalSpec(objective: deterministicRoutingPrompt, kind: .question), to: recordID)
            appendTaskRecordMessage(recordID, actor: "主线程记忆", role: "本地工作记忆", kind: .core, text: "命中本地工作记忆,无需远端模型。")
            appendTaskRecordMessage(recordID, actor: "灵枢", role: "答复", kind: .result, text: localAnswer)
            chatMessages.append(.init(speaker: "灵枢", text: localAnswer, isUser: false, taskRecordID: recordID))
            appendTrace(kind: .result, actor: "主线程记忆", title: "本地召回", detail: String(localAnswer.prefix(80)))
            finishTaskRecord(recordID, status: .answered, summary: localAnswer)
            rememberMainThreadTurn(prompt: deterministicRoutingPrompt, reply: localAnswer)
            return localAnswer
        }

        // 自主运行卡在 ask_user 提问上时，本轮输入即为答案：回填续跑（优先于一切常规分流）。
        // 这些早返回的续接handler都用各自的记录(自主/在岗/被卡住的派发任务),不需要本轮新建记录。
        if let answerAck = handleAutonomousAnswerIfNeeded(prompt: trimmedPrompt, taskRecordID: nil) {
            return answerAck
        }

        if let autonomousResponse = handleAutonomousRunCommandIfNeeded(prompt: trimmedPrompt, taskRecordID: nil) {
            return autonomousResponse
        }

        // 常驻灵枢在岗时,对话/语音直接喂给在岗执行会话(带其权限级与四肢),让它真去做。
        if let standingAck = handleStandingPersonInputIfNeeded(prompt: trimmedPrompt, taskRecordID: nil) {
            return standingAck
        }

        // 续接/追问(已有记录)→ 直接主回合,不分诊(继续这件事,不重新派发)。
        if let existing = existingTaskRecordID {
            let wasWaiting = taskExecutionRecords.first { $0.id == existing }?.taskOutcome == .waitingForUser
            if wasWaiting && Self.userInputDeniesPrerequisite(trimmedPrompt) {
                closeDispatchedTaskForDeniedPrerequisite(recordID: existing, answer: trimmedPrompt, appendChatUser: false)
                return "已按你的选择停在这里。"
            }
            let providesPrerequisite = Self.userInputProvidesPrerequisite(trimmedPrompt)
            if wasWaiting && providesPrerequisite { resolveUserProvidedGaps(recordID: existing) }
            let resumePrompt = wasWaiting && providesPrerequisite
                ? trimmedPrompt + "\n\n" + capabilityResumePreamble(recordID: existing)
                : trimmedPrompt
            return runMainAgentTurn(prompt: resumePrompt, taskRecordID: existing, resumeBlocked: wasWaiting)
        }

        // 新顶层输入:**上下文感知分诊**(近全 + 远压缩 + 可续任务线程)——
        //   reply(在回答/延续某条**派发的隔离任务**,如它问"做什么主题",哪怕隔了几条)→ 续跑**那条隔离会话**(带真上下文);
        //   chat(直答/问答)→ 留主 session(对话连续);
        //   task(全新执行/落盘/多步)→ 派发**独立隔离 session 并行跑**(不串主上下文)。
        // 记录**按需建**:reply 续用派发线程自己的记录(不另建),task/chat 各建一条。异步,真回复经气泡给出。
        // **顺序修(2026-06-23,监工"一问一答变成怪格式"):**分诊是异步(控制面往返),若只 append 用户消息、答复气泡
        // 等分诊完才出,rapid 连发就"问题全堆上面、答复全堆下面"。这里**同步先放一个答复占位气泡紧跟用户消息后**,
        // 保持 Q→A 交错;分诊定路由后:chat/派发**复用**它,入队/续接到已有线程则**移除**它。
        let placeholder = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        chatMessages.append(placeholder)
        let placeholderID = placeholder.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 注:主会话待答问题不再无脑把后续都接回主会话(那会阻塞——新任务本该派子线程并行)。
            // 改为把它放进分诊上下文(buildTriageContext 标⏳),由分诊器判:答复→续主会话提问;新任务→派子线程。
            // P1 目标认知:派生 GoalSpec 与分诊**并发**(不加 wall-clock 延迟);新建记录后绑定供执行引导/验收/记忆消费。
            // **性能优化(2026-06-23):先分诊,前置认知(GoalSpec/缺口/能力需求)仅 task 才派生**——
            // 问答/续接(chat/reply)直答不需,省掉那几次控制面往返 + 减少并发脑调用(双线串行下脑负载更低)。
            let triage = await self.classifyDispatch(trimmedPrompt)
            let isTask = self.goalSpecEnabled && triage.kind == .task
            // task 的三项前置认知并发(不互相加 wall-clock);非 task 全部跳过。
            async let goalSpecA: LingShuGoalSpec? = isTask ? self.deriveGoalSpec(for: trimmedPrompt, taskRecordID: nil) : nil
            async let gapA: LingShuGapAnalysis? = isTask ? self.deriveGapAnalysis(for: trimmedPrompt) : nil
            async let reqA: [LingShuCapabilityRequirement] = isTask ? self.deriveCapabilityRequirements(for: trimmedPrompt) : []
            let goalSpec = await goalSpecA
            let gap = await gapA
            let reqs = await reqA
            let newRecordBoundToGoal: @MainActor (LingShuGoalKind, String?) -> String = { fallbackKind, fallbackObjective in
                let rid = self.createTaskExecutionRecord(for: trimmedPrompt)
                var boundSpec = goalSpec
                if boundSpec == nil, fallbackKind != .unknown {
                    boundSpec = LingShuGoalSpec(objective: fallbackObjective ?? trimmedPrompt, kind: fallbackKind)
                }
                if fallbackKind == .task, boundSpec?.kind != .task {
                    boundSpec?.kind = .task
                }
                self.bindGoalSpec(boundSpec, to: rid)
                self.bindGapAnalysis(gap, to: rid)
                self.bindCapabilityRequirements(reqs, to: rid)
                return rid
            }
            switch triage.kind {
            case .reply:
                // 只续接**仍在进行/等待**的派发任务。已完成(completed)/已直答(answered)的任务不该被"回复"再续跑——
                // 否则会把已收尾的隔离会话再跑进垃圾态(如 demo 脚本子会话耗尽 → 泄出内部占位符"(脚本耗尽)")。
                // 问一件**已完成**派发任务的后续 = 普通提问,留主线程(其结论已经记忆/子→主可召回)。通用,不限 demo。
                let replyActive = triage.replyRecordID
                    .flatMap { id in self.taskExecutionRecords.first(where: { $0.id == id }) }
                    .map { $0.status != .completed && $0.status != .answered } ?? false
                if let rid = triage.replyRecordID, rid == self.pendingMainQuestionRecordID, replyActive {
                    // 续答**主会话**的提问:接回主会话(同一条记录,把答复喂回去),不另起新任务。
                    self.pendingMainQuestionRecordID = nil
                    let wasWaiting = self.taskExecutionRecords.first { $0.id == rid }?.taskOutcome == .waitingForUser
                    if wasWaiting && Self.userInputDeniesPrerequisite(trimmedPrompt) {
                        self.removeChatBubble(placeholderID)
                        self.closeDispatchedTaskForDeniedPrerequisite(recordID: rid, answer: trimmedPrompt, appendChatUser: false)
                        return
                    }
                    let providesPrerequisite = Self.userInputProvidesPrerequisite(trimmedPrompt)
                    if wasWaiting && providesPrerequisite { self.resolveUserProvidedGaps(recordID: rid) }
                    let resumePrompt = wasWaiting && providesPrerequisite
                        ? trimmedPrompt + "\n\n" + self.capabilityResumePreamble(recordID: rid)
                        : trimmedPrompt
                    self.appendTrace(kind: .route, actor: "主线程分诊", title: "续答主会话提问", detail: "判为对主会话提问的回答,接回原任务,不另起。")
                    _ = self.runMainAgentTurn(prompt: resumePrompt, taskRecordID: rid, resumeBlocked: true, existingBubbleID: placeholderID)
                } else if let rid = triage.replyRecordID, self.agentSubTaskRecords.values.contains(rid), replyActive {
                    self.removeChatBubble(placeholderID)   // 答复进那条派发线程自己的气泡,占位不再用
                    self.continueDispatchedThread(prompt: trimmedPrompt, recordID: rid)
                } else {   // 兜底:线程没了/已完成 → 当对话留主线程
                    _ = self.runMainAgentTurn(prompt: trimmedPrompt, taskRecordID: newRecordBoundToGoal(.question, nil), existingBubbleID: placeholderID)
                }
            case .task:
                if LingShuInteractionFulfillment.requiresLiveInteraction(trimmedPrompt) {
                    let rid = newRecordBoundToGoal(.task, triage.goal)
                    appendTrace(kind: .route, actor: "主线程分诊", title: "前台交互任务", detail: "演示/讲解/答疑类任务留在主线程生成材料并转入托管,不进后台队列。")
                    _ = self.runMainAgentTurn(prompt: trimmedPrompt, taskRecordID: rid, existingBubbleID: placeholderID)
                    return
                }
                // 主界面 task **串行**(同时只一条在执行);**满了进可见队列区等待**(不直接派发、可删除),前一条完成后自动晋级(用户定调)。
                // **竞态修(2026-06-23,监工"信息池丢了"):**容量门改用**同步 MainActor 状态**(活跃派发气泡数 + 队列区数),
                // 临界区(读数→判→派发/入队)**无 await**。原 `await runningCount()` 的 await 是交错点:rapid 连发的多条会
                // 在此交错、全读到旧 running=0、全绕过队列直接派发(溢出被编排器内部不可见地兜住,可见队列区永不建)。
                // dispatchedTaskBubbles 派发时同步置、收尾时同步清(见 Triage),正是无竞态的活跃派发计数。capacity 是常量,先读不影响。
                let cap = await self.agentOrchestrator.capacity()
                self.pruneInactiveDispatchedTaskBubbles()
                let active = self.dispatchedTaskBubbles.count + self.queuedDispatchTasks.count
                if Self.shouldQueueDispatch(running: active, capacity: cap) {
                    self.enqueueDispatchTask(prompt: trimmedPrompt, goal: triage.goal, goalSpec: goalSpec, gap: gap,
                                             requirements: reqs, existingBubbleID: placeholderID)
                } else {
                    // 要占屏实时演示/互动时,由大脑自己调 enter_managed_mode 申请、弹窗征主人同意后才转入托管。
                    self.dispatchIsolatedTask(prompt: trimmedPrompt, taskRecordID: newRecordBoundToGoal(.task, triage.goal), goal: triage.goal, existingBubbleID: placeholderID)
                }
            case .chat:
                _ = self.runMainAgentTurn(prompt: trimmedPrompt, taskRecordID: newRecordBoundToGoal(.question, nil), existingBubbleID: placeholderID)
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
