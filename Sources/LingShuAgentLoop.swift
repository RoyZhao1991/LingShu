import Foundation

/// 统一 agent 编排循环(范式骨干)。
///
/// 取代「Swift 启发式前置门 + 一次性路由」:模型作为编排者,在一条隔离会话里
/// 持续 `读上下文+工具 → 产出文本或工具调用 → 执行工具 → 回灌结果 → 再来`,直到收尾或到轮次上限。
/// 任务拆分、续接、回指、路由都收敛为「模型读上下文后的推理」,不再各写一套补丁。
///
/// 模型与工具均为注入接口,故循环本身可脱离网络单测。

enum LingShuAgentRole: String, Equatable, Sendable {
    case system, user, assistant, tool
}

/// 模型发起的一次工具调用。arguments 按 OpenAI 风格以 JSON 字符串承载。
struct LingShuAgentToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct LingShuAgentMessage: Equatable, Sendable {
    var role: LingShuAgentRole
    var content: String
    var toolCalls: [LingShuAgentToolCall]
    var toolCallID: String?

    init(role: LingShuAgentRole, content: String, toolCalls: [LingShuAgentToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// 一个工具:名称、描述、参数 JSON schema、执行体(收到 arguments JSON,返回结果文本)。
struct LingShuAgentTool: Sendable {
    let name: String
    let description: String
    let parametersJSON: String
    let handler: @Sendable (String) async -> String

    init(name: String, description: String, parametersJSON: String = "{\"type\":\"object\",\"properties\":{}}", handler: @escaping @Sendable (String) async -> String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.handler = handler
    }
}

/// 模型一轮的产出:要么要求调用工具,要么给出最终文本,要么**基础设施故障**(网关/网络不可达,重试耗尽)。
enum LingShuAgentModelResponse: Sendable {
    case toolCalls([LingShuAgentToolCall])
    case text(String)
    /// 基础设施中断:网关/网络不可达且重试耗尽——**非任务失败**。循环据此返回 `.interrupted`,保留上下文,等重连后续跑。
    case failed(reason: String)
}

/// 编排循环依赖的模型接口(注入,便于真实网关与 mock 替换)。
protocol LingShuAgentModel: Sendable {
    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse
    /// 流式变体:`onTextDelta` 在最终答复轮逐字回调(async 串行 → 保证到 UI 的顺序)。
    /// 默认回退非流式 `respond`(脚本模型/测试/不支持流式的供应商无需各自实现)。
    func respondStreaming(messages: [LingShuAgentMessage], tools: [LingShuAgentTool], onTextDelta: @Sendable (String) async -> Void) async -> LingShuAgentModelResponse
}

extension LingShuAgentModel {
    func respondStreaming(messages: [LingShuAgentMessage], tools: [LingShuAgentTool], onTextDelta: @Sendable (String) async -> Void) async -> LingShuAgentModelResponse {
        await respond(messages: messages, tools: tools)
    }
}

/// 脚本化模型:按预设序列逐轮返回。用于 dev/演示(确定性,不依赖网络)。
/// 真实模型适配器(接模型网关 + tool_calls)是下一步,接口同此协议。
final class LingShuScriptedAgentModel: LingShuAgentModel, @unchecked Sendable {
    private var script: [LingShuAgentModelResponse]
    private var index = 0
    init(_ script: [LingShuAgentModelResponse]) { self.script = script }
    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
        defer { index += 1 }
        return index < script.count ? script[index] : .text("(脚本耗尽)")
    }
}

enum LingShuAgentRunResult: Equatable, Sendable {
    case completed(text: String)
    /// 卡住:模型调用了"阻塞工具"(如 ask_user),需要外部(用户/主会话)给答案后才能续跑。
    case blocked(question: String)
    case maxTurnsReached(lastText: String)
    /// **基础设施中断**(网络/网关不可达,重试耗尽):**非任务失败**。上下文已原样保留(没追加假消息),
    /// 重连后 `continueLoop()` 即可从中断处接着跑。供「断网→暂停→重连自动续」用,绝不当成 `.completed`/`.failed`。
    case interrupted(reason: String)
}

/// 一条隔离会话 = 一条任务线程的上下文与循环。多会话并发即多任务并行(配合有界并发管理器)。
/// 核心循环变体(新旧循环热切换):`.classic`=经典连续循环;`.nested`=嵌套分阶段验收循环(大 LOOP 含多个子 LOOP/阶段,
/// 任务阶段验交付物、互动阶段不验,阶段间断点续)。两者都实现 `LingShuAgentSessioning`,由 `makeAgentSession` 工厂按开关返回。
/// String raw:持久化到 UserDefaults(跨重启保留所选引擎)。
enum LingShuAgentLoopVariant: String, Sendable { case classic, nested }

/// **核心循环的对外接口**(2026-06-19 抽出):把"驱动一段会话"的能力抽象成协议,便于**另起一个新循环、新旧热切换**
/// (见 `makeAgentSession` 工厂 + 开关)。现有 `LingShuAgentSession` 是其一份实现(经典连续循环),将来"嵌套分阶段验收"的
/// 新循环只要也实现本协议即可被工厂按开关返回、与旧的并存切换。actor 约束:存在体(any)按 actor 隔离、跨 actor 调用自动 async。
protocol LingShuAgentSessioning: Actor {
    var isBlocked: Bool { get }
    var turnsUsed: Int { get }
    var toolInvocations: [String] { get }
    var messages: [LingShuAgentMessage] { get }
    func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?)
    func send(_ userText: String) async -> LingShuAgentRunResult
    func resume(_ answer: String) async -> LingShuAgentRunResult
    func continueLoop() async -> LingShuAgentRunResult
    func injectCorrection(_ text: String) -> Bool
    func injectBriefing(_ text: String)
}

actor LingShuAgentSession: LingShuAgentSessioning {
    let id: String
    let tools: [LingShuAgentTool]
    let model: any LingShuAgentModel
    let maxTurns: Int
    /// 阻塞工具名:模型调用这些工具即视为"卡住等外部输入"(默认 ask_user)。
    let blockingToolNames: Set<String>
    /// 上下文历史窗口上限(非系统消息条数)。0=不裁剪。常驻主会话设上限,杜绝旧任务无限堆积污染新任务
    /// (例:被问"做自我介绍 PPT"却把几轮前的「人工智能发展简史.pptx」当素材塞进去)。
    let maxHistoryMessages: Int
    /// 工具调度器(差距7-A·可替换模块):默认串行(经典行为零变更);`makeAgentSession` 生产侧注入并行实现降延迟。
    private let toolDispatcher: any LingShuToolDispatching
    /// 历史压缩器(差距4·可替换模块):nil=走内置经典「按条数」蒸馏路径(零变更兜底);生产侧注入 token 分层压缩器。
    private let historyCompactor: (any LingShuHistoryCompacting)?
    /// 压缩抽出的关键事实回灌口(差距4·超越):把丢弃段事实 remember 进知识图谱实现近无损。nil=不记(核心循环不依赖 Memory)。
    private let factSink: (@Sendable ([String]) async -> Void)?
    /// 当前向模型暴露的工具名集(差距7-B·延迟加载):nil=暴露全部(经典零变更);非 nil=只把集内工具的 schema 喂模型,
    /// 全部 handler 仍注册可执行,search_tools 激活后下一回合即见(动态扩张)。
    private let exposedToolNames: LingShuExposedToolSet?
    private(set) var messages: [LingShuAgentMessage]
    private(set) var turnsUsed = 0
    /// 按序记录工具调用名,便于可观测与测试。
    private(set) var toolInvocations: [String] = []
    /// 卡住时挂起的阻塞工具调用 id(供 resume 回填答案)。
    private var pendingBlockToolCallID: String?
    /// 用户中途下达的纠正(看到 agent 跑偏时干预):循环在**回合边界**采纳,立即据此调整方向。
    private var pendingCorrection: String?
    /// 子任务完成后回灌主线程的**简报**(信息同步,非完整上下文同步):在回合边界作为 system 提示注入。
    private var pendingBriefings: [String] = []
    /// 最终答复逐字流式的接收口(注入)。**非 nil 才走流式**——只有主会话设它(逐字进气泡 + 按句早读 TTS);
    /// 子会话/自主/测试不设 → 继续走非流式 `respond`,行为零变更。
    private var textDeltaSink: (@Sendable (String) async -> Void)?

    /// 循环不变量违反记录(差距1·架网):回合边界检查到的违反进这里,fuzz/单测读它精确断言"本会话恒良构"。
    /// 软断言——只记录不 crash;有上限防长跑无界增长。
    private(set) var recordedInvariantViolations: [LingShuLoopInvariantViolation] = []
    /// 本会话上一次循环退出的结构化原因码(差距1.3 遥测)。
    private(set) var lastExitReason: LingShuAgentExitReason?

    /// 回合边界不变量检查:构造快照 → 检查 → 记录到会话内列表 + 全局遥测。纯观测,绝不改流程/不 crash。
    private func checkInvariants(at boundary: LingShuLoopBoundary) {
        guard LingShuLoopInvariants.runtimeChecksEnabled else { return }
        let snapshot = LingShuLoopStateSnapshot(
            messages: messages,
            isRunning: isRunning,
            pendingBlockToolCallID: pendingBlockToolCallID,
            hasPendingCorrection: pendingCorrection != nil,
            maxHistoryMessages: maxHistoryMessages,
            compactionBudget: historyCompactor?.budget   // 注入了压缩器→按其契约(条数/token)校验 I6;否则回退条数
        )
        let violations = LingShuLoopInvariants.check(snapshot, at: boundary)
        guard !violations.isEmpty else { return }
        recordedInvariantViolations.append(contentsOf: violations)
        if recordedInvariantViolations.count > 128 {
            recordedInvariantViolations.removeFirst(recordedInvariantViolations.count - 128)
        }
        LingShuLoopInvariantTelemetry.record(violations, boundary: boundary)
        #if DEBUG
        print("⚠️ [循环不变量] 会话\(id) @\(boundary): \(violations.map(\.description).joined(separator: "; "))")
        #endif
    }

    /// runLoop 返回后(`defer isRunning=false` 已生效)记录终态不变量。统一三个入口(send/resume/continueLoop)共用。
    /// 退出原因码由 runLoop 各 return 分支就地写 `lastExitReason`(同一 `.maxTurnsReached` 可来自停滞/只读空转/天花板/取消,需就地区分)。
    @discardableResult
    private func recordTerminal(_ result: LingShuAgentRunResult) -> LingShuAgentRunResult {
        checkInvariants(at: .terminal(LingShuLoopTerminalKind(result)))
        return result
    }

    init(
        id: String,
        system: String? = nil,
        initialMessages: [LingShuAgentMessage] = [],
        tools: [LingShuAgentTool],
        model: any LingShuAgentModel,
        maxTurns: Int = 40,   // 安全天花板(防失控),非目标预算;目标达成/卡住/停滞才是真正的停止位
        maxHistoryMessages: Int = 0,   // 0=不裁剪(短命子会话);常驻主会话传正数设窗口
        blockingToolNames: Set<String> = LingShuHumanInputEnvelope.blockingToolNames,
        toolDispatcher: any LingShuToolDispatching = LingShuSerialToolDispatcher(),
        historyCompactor: (any LingShuHistoryCompacting)? = nil,
        factSink: (@Sendable ([String]) async -> Void)? = nil,
        exposedToolNames: LingShuExposedToolSet? = nil
    ) {
        self.id = id
        self.tools = tools
        self.model = model
        self.maxTurns = max(1, maxTurns)
        self.maxHistoryMessages = max(0, maxHistoryMessages)
        self.blockingToolNames = blockingToolNames
        self.toolDispatcher = toolDispatcher
        self.historyCompactor = historyCompactor
        self.factSink = factSink
        self.exposedToolNames = exposedToolNames
        var seeded: [LingShuAgentMessage] = []
        if let system { seeded.append(.init(role: .system, content: system)) }
        seeded.append(contentsOf: initialMessages)   // 跨重启续上:历史对话 seed 进上下文
        self.messages = seeded
    }

    var isBlocked: Bool { pendingBlockToolCallID != nil }

    /// 设置/清除最终答复逐字流式接收口。只有主会话调它(把 delta 接进 UI 气泡);传 nil 即关闭流式。
    func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {
        textDeltaSink = sink
    }

    /// 投入一条用户输入,跑完整循环直到模型收尾、卡住或到轮次上限。
    func send(_ userText: String) async -> LingShuAgentRunResult {
        repairOrphanToolCalls()   // 续接前修齐上一回合飞行中被取消留下的孤儿 tool_call(打断恢复泄漏修复)→ 下面的不变量检查见到的是良构 history
        pendingCorrection = nil   // 新回合不带上一回合可能残留的纠正
        consumePendingBriefings() // 子任务简报先入上下文(在用户新输入之前)——主线程信息同步
        await compactHistoryIfNeeded()   // 回合边界:超窗口的早段**语义压缩成前情提要**(对标 CC auto-compaction),失败回退硬裁剪
        messages.append(.init(role: .user, content: userText))
        checkInvariants(at: .afterCompaction)   // 不变量:压缩后历史在预算内且良构(I6+I1+I2)
        return recordTerminal(await runLoop())
    }

    /// 子任务简报回灌(信息同步,非完整上下文):只把**摘要**塞进主线程,不搬子任务的完整 transcript。
    /// 在回合边界作为最高优先级 system 提示注入(像 codex 的 subagent 汇报)。
    func injectBriefing(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingBriefings.append(trimmed)
    }

    /// 回合边界采纳子任务简报:合并成一条 system 提示注入(不必复述、仅供主线程知悉进展)。
    private func consumePendingBriefings() {
        guard !pendingBriefings.isEmpty else { return }
        let joined = pendingBriefings.map { "- \($0)" }.joined(separator: "\n")
        pendingBriefings.removeAll()
        messages.append(.init(role: .system, content: "【子任务进展简报(仅供你知悉当前状态,不必主动复述)】\n\(joined)"))
    }

    /// 流程纠正(干预):用户看到 agent 跑偏时中途下达的纠正。**不直接动 messages**(避免与在飞工具调用
    /// 产生半截状态),只置标志;循环在回合边界(工具结果已补齐 / 模型刚出文本)安全地把它作为最高优先级
    /// user 消息注入,模型下一步即据此改方向。返回是否被一个**正在跑的循环**接住(false=当前没在跑)。
    @discardableResult
    func injectCorrection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pendingCorrection = trimmed
        return isRunning
    }

    /// 当前是否有循环在跑(供干预判定)。
    private(set) var isRunning = false

    /// 回合边界采纳纠正:此刻 messages 良构(上一步工具结果已补齐),把纠正作为最高优先级 user 注入。
    private func consumePendingCorrection() -> Bool {
        guard let correction = pendingCorrection else { return false }
        pendingCorrection = nil
        messages.append(.init(role: .user, content: "【用户中途纠正,最高优先级——立即停止当前偏离方向,据此重新规划并执行】\(correction)"))
        return true
    }

    /// 回合边界裁剪:系统消息(身份/seed)永远保留;非系统历史只留最近 `maxHistoryMessages` 条。
    /// **只在 send 入口调用**——此刻上一回合已收尾,不存在"裁掉某个 tool_call 却留下其 tool 结果"的半截调用。
    /// 仍兜底:裁剪后若开头是孤儿 tool 结果(其 assistant 调用已被裁),继续往后丢到一条完整起点,避免 OpenAI 协议报错。
    private func trimHistoryIfNeeded() {
        guard maxHistoryMessages > 0 else { return }
        let systemCount = messages.prefix { $0.role == .system }.count
        let body = Array(messages[systemCount...])
        guard body.count > maxHistoryMessages else { return }
        var kept = Array(body.suffix(maxHistoryMessages))
        while let first = kept.first, first.role == .tool { kept.removeFirst() }   // 不留孤儿 tool 结果
        messages = Array(messages[..<systemCount]) + kept
    }

    /// **续接前修齐孤儿 tool_call(打断恢复不变量泄漏修复,2026-06-22,见 [[verify-gate-bypass-batchinterrupt-leak]])**:
    /// 飞行中被取消(`lingshu_stop`)可能停在"assistant 已声明 tool_calls、对应 tool 结果尚未回填"之间,
    /// 使持久会话 history 留下**未应答 tool_call**。下一回合 `checkInvariants` 会据此记 I1/I2——网关
    /// `sanitizeToolCallSequence` 虽在序列化时兜底防 400,但会话层不变量检查发生在它之前 → 违反照记、
    /// `loopInvariantViolations` 爬升(实测打断恢复 0→3→8)。这里在每个续接入口(send/resume/continueLoop)
    /// 先补齐:为每个 assistant 声明却无紧随 tool 结果的 tool_call 补一条合成结果,使会话层与网关同口径良构。
    /// `pendingBlockToolCallID`(human-in-the-loop 合法 open 调用)豁免;无孤儿时零改动(干净流程不受影响)。
    private func repairOrphanToolCalls() {
        guard messages.contains(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }) else { return }
        var rebuilt: [LingShuAgentMessage] = []
        rebuilt.reserveCapacity(messages.count)
        var i = 0
        var repairedAny = false
        while i < messages.count {
            let m = messages[i]
            rebuilt.append(m); i += 1
            guard m.role == .assistant, !m.toolCalls.isEmpty else { continue }
            // 收集紧随该 assistant 的 tool 结果(良构序列里 tool 结果紧跟其声明)。
            var provided = Set<String>()
            while i < messages.count, messages[i].role == .tool {
                if let id = messages[i].toolCallID { provided.insert(id) }
                rebuilt.append(messages[i]); i += 1
            }
            for call in m.toolCalls where !provided.contains(call.id) && call.id != pendingBlockToolCallID {
                rebuilt.append(.init(role: .tool,
                    content: "（该工具调用因上一回合被中断而未完成，补占位以保持消息结构良构。）",
                    toolCallID: call.id))
                repairedAny = true
            }
        }
        if repairedAny { messages = rebuilt }
    }

    /// 回合边界**语义压缩**:历史超窗口时,把要丢弃的早段用模型蒸馏成一条「前情提要」,替代硬丢弃——
    /// 长会话不丢早先的决策/产物路径/已确认信息(对标 Claude Code 的 auto-compaction,补"硬丢中段"短板)。
    /// 提要作为 body 首条流转,下次溢出会被连同新内容再压缩=**滚动摘要**。蒸馏失败/为空 → 回退硬裁剪,绝不卡住。
    private func compactHistoryIfNeeded() async {
        // 差距4·可替换模块:注入了压缩器(生产侧=token 分层 + 知识图谱无损召回)→ 走它;
        // 抽出的关键事实经 factSink remember 进图谱(核心循环不直接依赖 Memory,保持模块解耦)。
        if let compactor = historyCompactor {
            if let result = await compactor.compact(messages: messages, model: model) {
                messages = result.messages
                if !result.extractedFacts.isEmpty, let sink = factSink {
                    await sink(result.extractedFacts)
                }
            }
            return
        }
        // 未注入 → 内置经典「按消息条数」整段蒸馏路径(零变更兜底)。
        guard maxHistoryMessages > 0 else { return }
        let systemCount = messages.prefix { $0.role == .system }.count
        let body = Array(messages[systemCount...])
        guard body.count > maxHistoryMessages else { return }
        let keepRecent = max(1, maxHistoryMessages - 1)        // 留一格给提要
        let dropCount = body.count - keepRecent
        guard dropCount >= 2 else { trimHistoryIfNeeded(); return }
        let dropped = Array(body.prefix(dropCount))
        let transcript = dropped.map { "[\($0.role)] " + String($0.content.prefix(1200)) }.joined(separator: "\n")
        let sys = LingShuAgentMessage(role: .system, content: "你是对话压缩器。把下面这段较早的 agent 对话压成简洁【前情提要】:只留对后续推进有用的——关键决策/已产出文件的绝对路径/已确认事实/未决问题/约束。要点式,别复述客套和中间废话。只输出提要正文。")
        let usr = LingShuAgentMessage(role: .user, content: transcript)
        let resp = await model.respond(messages: [sys, usr], tools: [])
        var summary = ""
        if case .text(let s) = resp { summary = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !summary.isEmpty else { trimHistoryIfNeeded(); return }   // 蒸馏失败 → 回退硬裁剪
        var kept = Array(body.suffix(keepRecent))
        while let first = kept.first, first.role == .tool { kept.removeFirst() }
        let summaryMsg = LingShuAgentMessage(role: .user, content: "【前情提要(早前对话已压缩,供你延续)】\n\(summary)")
        messages = Array(messages[..<systemCount]) + [summaryMsg] + kept
    }

    /// 续接:把外部给的答案回填到卡住的阻塞工具调用上,继续跑循环。
    func resume(_ answer: String) async -> LingShuAgentRunResult {
        guard let pending = pendingBlockToolCallID else {
            return await send(answer)   // 没在卡 → 当普通输入
        }
        messages.append(.init(role: .tool, content: answer, toolCallID: pending))
        pendingBlockToolCallID = nil
        repairOrphanToolCalls()   // 填回阻塞答案后,修齐其余孤儿(若打断曾留下)→ runLoop 首个不变量检查良构
        return recordTerminal(await runLoop())
    }

    /// 重连后续跑(断网恢复用):**不注入任何新消息**,直接接着跑循环——上下文停在中断前的良构状态,
    /// 重发的就是中断那一步的模型调用。`step` 重置=新的一段预算(与 send/resume 一致)。
    func continueLoop() async -> LingShuAgentRunResult {
        repairOrphanToolCalls()   // 重连续跑前防御性修齐(中断点若曾留孤儿)→ 不变量检查良构
        return recordTerminal(await runLoop())
    }

    /// 连续多少次发起完全相同的工具调用即判"原地打转"(停滞)。
    static let stuckRepeatThreshold = 5

    /// **可选脚手架工具**(非任务目标本身):卡在它们上绝不交还,改为纠偏让模型跳过、直接做任务。
    static let optionalScaffoldTools: Set<String> = ["update_plan"]

    /// 会改动交付物的工具(产出"进展"的标志)。其余(read_file/run_command 跑测试/list_directory…)算"验证/查看"。
    static let mutatingToolNames: Set<String> = ["write_file", "edit_file"]
    /// **过度自测收敛**(根治"游戏早做好了却反复跑测试 35 分钟不宣布完成"):已产出过文件后,连续这么多步
    /// **不再改动任何文件**(只在反复测试/查看)→ 工作其实已完成。`overValidationNudgeAt` 先提示收尾;
    /// 再不收尾到 `overValidationForceAt` 就**强制收尾**(返回 .completed),交**独立验收(checker)**判定,
    /// 而不是让 maker 无限自测空转。`stuck` 检测只抓"完全相同"调用,抓不到"每次略不同的测试空转",故另设此门。
    static let overValidationNudgeAt = 10
    static let overValidationForceAt = 20
    /// **只读空转收敛**(兼容各种模型,根治弱模型"反复读同一份文件就是不动手改/不收尾"):**还没产出过任何改动**就连续
    /// 这么多步只读/查看 → `readOnlyStallNudgeAt` 先催它动手(产出/答复);再不动到 `readOnlyStallForceAt` 就诚实交还,
    /// 别无限空转。与上面的过度自测门互补:那个抓"改完后空转",这个抓"从没改过的犹豫空转"。
    static let readOnlyStallNudgeAt = 8
    static let readOnlyStallForceAt = 16

    /// 目标驱动循环:**停止条件只有「目标达成(模型给出最终答复)/ 卡住等人(ask_user)/ 原地打转交还」**。
    /// `maxTurns` 不是目标预算,而是防失控的安全天花板(高位,正常远到不了)——不靠它来"到点收工"。
    /// 模型自己判断完成就 `.text` 收尾;撞墙就换方法继续(失败结果回灌进上下文,这就是 agent 循环)。
    private func runLoop() async -> LingShuAgentRunResult {
        isRunning = true
        defer { isRunning = false }
        var lastText = ""
        var recentToolSignatures: [String] = []
        var step = 0
        // 过度自测收敛:已产出过文件后,连续多少步没再改文件(只测试/查看)。sawMutation 后才计,纯探索期不算。
        var turnsSinceMutation = 0
        var sawMutation = false
        var nudgedOverValidation = false
        var nudgedReadOnlyStall = false
        while step < maxTurns {   // maxTurns = 安全天花板,非目标停止位
            // 用户停止:真停(任务取消)→ 诚实交还,不假装收尾。
            if Task.isCancelled {
                lastExitReason = .userCancelled
                return .maxTurnsReached(lastText: lastText.isEmpty ? "（已被用户停止）" : lastText)
            }
            // 回合边界采纳子任务简报(信息同步)+ 纠正(最高优先级 user 指令)。
            consumePendingBriefings()
            _ = consumePendingCorrection()
            step += 1
            turnsUsed += 1
            // 不变量:此刻上下文必须是良构 OpenAI 序列、无未应答 tool_call(I1+I2)——即将喂给模型。
            checkInvariants(at: .beforeModelCall)
            // 差距7-B:延迟加载时只把当前暴露集内的工具 schema 喂模型(全部 handler 仍可执行);nil=全暴露(零变更)。
            let activeTools: [LingShuAgentTool]
            if let exposed = exposedToolNames {
                activeTools = tools.filter { exposed.contains($0.name) }
            } else {
                activeTools = tools
            }
            // 设了 delta 接收口(仅主会话)→ 走流式,最终答复逐字回调进气泡;否则非流式(子会话/自主/测试,零变更)。
            let response: LingShuAgentModelResponse
            if let sink = textDeltaSink {
                response = await model.respondStreaming(messages: messages, tools: activeTools, onTextDelta: sink)
            } else {
                response = await model.respond(messages: messages, tools: activeTools)
            }
            switch response {
            case .failed(let reason):
                // 基础设施中断(网络/网关不可达):**不收尾、不污染上下文**——绝不追加假的"调用失败"助手消息,
                // 让 messages 原样停在中断前的良构状态(上一步若是工具循环,tool 结果已补齐)。
                // 返回 .interrupted:上层据此把任务标"已暂停"并保留本会话,重连后 continueLoop() 重发这步模型调用即续上。
                lastExitReason = .infraInterrupted
                return .interrupted(reason: reason)
            case .text(let text):
                messages.append(.init(role: .assistant, content: text))
                // 模型自认收尾,但用户刚下了纠正 → 不收尾,带着纠正继续(纠正跑偏的"假收尾")。
                if pendingCorrection != nil { continue }
                lastExitReason = .normalCompletion
                return .completed(text: text)
            case .toolCalls(let calls):
                guard !calls.isEmpty else {
                    lastExitReason = .normalCompletion
                    return .completed(text: lastText)
                }
                messages.append(.init(role: .assistant, content: "", toolCalls: calls))
                // 阻塞工具:挂起等外部答案(human-in-the-loop)。**先把同回合的其余非阻塞工具执行掉并补结果**——
                // 否则它们成为永远没有 tool 结果的孤儿调用(I2:resume 只回填阻塞那条,其余仍未应答 → 下次喂模型即网关 400)。
                // 这就是"不变量逼出来的正确性":阻塞前清干净本回合,留下的唯一 open 调用就是 pending 那条。
                if let blocking = calls.first(where: { blockingToolNames.contains($0.name) }) {
                    // 同回合非阻塞工具先执行掉补结果(经调度器,可并行),只留阻塞那条作唯一 open 调用(I2)。
                    // 若模型一次发出多个阻塞工具,只保留第一个等待用户,其余补合成结果；绝不执行另一个
                    // ask_form/ask_choice 的 handler,否则 handler 自身等待用户会把本轮重新卡死。
                    let executable = calls.filter { $0.id != blocking.id && !blockingToolNames.contains($0.name) }
                    let skippedBlocking = calls.filter { $0.id != blocking.id && blockingToolNames.contains($0.name) }
                    let outcomes = await toolDispatcher.dispatch(executable, tools: tools)
                    var answeredIDs = Set<String>()
                    for outcome in outcomes {
                        toolInvocations.append(outcome.name)
                        messages.append(.init(role: .tool, content: outcome.output, toolCallID: outcome.id))
                        answeredIDs.insert(outcome.id)
                    }
                    for call in skippedBlocking {
                        messages.append(.init(role: .tool,
                            content: "（本回合已有一个用户确认在等待，本确认项已跳过；请收到用户答案后再继续确认。）",
                            toolCallID: call.id))
                        answeredIDs.insert(call.id)
                    }
                    // 取消恢复·孤儿根治:非阻塞工具若因取消只返回部分结果,给未应答的补合成结果(同主路径)。
                    for call in calls where call.id != blocking.id && !answeredIDs.contains(call.id) {
                        messages.append(.init(role: .tool,
                            content: "（该工具调用被中断,未取得结果;补占位以保持消息结构良构。）",
                            toolCallID: call.id))
                    }
                    toolInvocations.append(blocking.name)
                    pendingBlockToolCallID = blocking.id
                    lastExitReason = .blockedAwaitingInput
                    return .blocked(question: Self.blockedPrompt(for: blocking))
                }
                // 停滞检测:连续 N 次发起完全相同的工具调用 = 原地打转。**空/畸形参数归一为 #EMPTY**——
                // 否则任何弱脑反复空调用同一工具(参数JSON略有差异)签名不同会漏判(实测某脑空 run_command×8 没被拦)。通用,非特判。
                let signature = calls.map { Self.normalizedToolSignature(name: $0.name, argsJSON: $0.argumentsJSON) }.joined(separator: "|")
                recentToolSignatures.append(signature)
                let tail = recentToolSignatures.suffix(Self.stuckRepeatThreshold)
                var pendingSteer: String? = nil
                if tail.count == Self.stuckRepeatThreshold, Set(tail).count == 1 {
                    let name = calls.first?.name ?? "同一动作"
                    if tail.first?.contains("#EMPTY") == true {
                        // **空/畸形参数反复调用同一工具(任何弱脑通病,非特判)**:它只是没填对参数、不是任务做不动 →
                        // 纠偏让它带齐参数重调,别交还。清签名史给它重来的机会。
                        recentToolSignatures.removeAll()
                        pendingSteer = "【系统纠偏】你连续多次调用「\(name)」都没带上必需参数(空调用),所以一直没成。请**带齐完整参数重新调用**(如 run_command 要给 command、write_file 要给 path 和 content),或换个工具/方式把事做出来——别再发空调用了。"
                    } else if Self.optionalScaffoldTools.contains(name) {
                        // 卡在**可选脚手架工具**(如 update_plan)上:计划不是目标——绝不为它交还。
                        // 清掉签名史 + 执行完这次后注入纠偏,让模型跳过计划、直接用通用工具把任务做出来。
                        recentToolSignatures.removeAll()
                        pendingSteer = "【系统纠偏】update_plan 这步反复失败,但它只是**可选的计划工具、不是任务本身**。别再调用它了——直接用 write_file / run_command / web_search 等把用户真正要的事做出来,完成后给出结果。"
                    } else {
                        // 卡在**真任务动作**上才诚实交还,且给结果+原因+下一步,不是空喊"走不通"。
                        // 这一步的 assistant tool_calls **不执行**直接交还——必须给它们补上合成 tool 结果(I2),
                        // 否则留下悬空的未应答调用,之后 send/resume 续接时网关 400。
                        appendSyntheticToolResults(for: calls, note: "（已停止:反复尝试未推进,转交。）")
                        lastExitReason = .stuckHandback
                        return .maxTurnsReached(lastText: "（我反复尝试「\(name)」\(Self.stuckRepeatThreshold) 次都没推进。最近结果:\(lastText.prefix(200))。我先停下,需要你确认一个关键点或给我缺的信息,我换条路继续。）")
                    }
                }
                // 过度自测收敛:已产出文件后,连续多步不再改任何文件 = 在反复验证/查看空转。
                if calls.contains(where: { Self.mutatingToolNames.contains($0.name) }) {
                    sawMutation = true; turnsSinceMutation = 0
                } else {
                    turnsSinceMutation += 1
                }
                if sawMutation, turnsSinceMutation == Self.overValidationNudgeAt, !nudgedOverValidation, pendingSteer == nil {
                    nudgedOverValidation = true
                    pendingSteer = "【系统纠偏】你已经连续很多步只在测试/查看、没有再改动任何文件——说明要做的东西已经做完了。**别再重复验证空转**,下一步请直接给出最终交付文本(做了什么 + 产出物绝对路径 + 怎么运行/打开),不要再调用工具。"
                }
                // **只读空转催动手**:还没产出过任何改动,就连续多步只读/查看(反复 read_file/cat 同一份)→ 催它立刻动手。
                // 不强求 mutate(纯问答可直接答),所以措辞兼顾"改"与"答",不误伤只读任务;对各种模型都通用。
                if !sawMutation, turnsSinceMutation >= Self.readOnlyStallNudgeAt, !nudgedReadOnlyStall, pendingSteer == nil {
                    nudgedReadOnlyStall = true
                    pendingSteer = "【系统提醒】你已经连续 \(turnsSinceMutation) 步只在读取/查看、还没产出任何东西。掌握足够信息就**立刻动手产出**——要改/建文件就用 edit_file/write_file 真的改(别只 read_file/cat 反复看),纯问答就直接给最终答复。别再反复读同一份内容空转。"
                }
                // 差距7-A:同回合无依赖工具经调度器执行(生产侧=并行降延迟);结果**与发起同序**返回,
                // 据此补 tool 结果保持 OpenAI 协议良构(每个 tool_call 必有同 id 的 tool 响应)。
                let outcomes = await toolDispatcher.dispatch(calls, tools: tools)
                var answeredIDs = Set<String>()
                for outcome in outcomes {
                    toolInvocations.append(outcome.name)
                    lastText = outcome.output
                    messages.append(.init(role: .tool, content: outcome.output, toolCallID: outcome.id))
                    answeredIDs.insert(outcome.id)
                }
                // **取消恢复·孤儿根治(2026-06-22)**:飞行中取消(`lingshu_stop`)可能让调度器只返回部分结果——
                // 给本回合**未拿到结果的 tool_call 当场补合成结果**,确保 assistant 声明的每个调用都有应答。
                // 否则该回合的 `.terminal` 不变量检查就当场记 I1/I2(实测打断恢复 #2 仍泄漏 8 的真因:入口修复只防下一回合、防不住本回合终态)。
                for call in calls where !answeredIDs.contains(call.id) {
                    messages.append(.init(role: .tool,
                        content: "（该工具调用被中断,未取得结果;补占位以保持消息结构良构。）",
                        toolCallID: call.id))
                }
                if let steer = pendingSteer {
                    messages.append(.init(role: .user, content: steer))
                }
                // 强制收尾(在工具执行后判,保证 messages 良构可被验收/resume):提示过仍空转 → 工作已完成,
                // 停止 maker 无限自测,**返回 .completed 交独立验收(checker)** 判定,而非无界空转或被撞顶误判异常。
                if sawMutation, turnsSinceMutation >= Self.overValidationForceAt {
                    lastExitReason = .overValidationForced
                    return .completed(text: lastText.isEmpty ? "（工作已完成,产出物已落盘,停止重复验证,交付独立验收。）" : lastText)
                }
                // 只读空转到顶仍没动手 → 诚实交还(不假装完成,因为确实没产出),换路或等用户给方向(兼容犹豫的弱模型)。
                if !sawMutation, turnsSinceMutation >= Self.readOnlyStallForceAt {
                    lastExitReason = .readOnlyStallHandback
                    return .maxTurnsReached(lastText: "（我连续 \(turnsSinceMutation) 步只在读取查看、没能动手产出——这步我判断不清,先停下。最近看到:\(lastText.prefix(160))。给我个方向或缺的信息,我换条路继续。）")
                }
            }
        }
        // 撞到安全天花板(极少):同样诚实交还,不假装收尾。
        lastExitReason = .maxTurnsCeiling
        return .maxTurnsReached(lastText: lastText.isEmpty ? "（已推进很多步仍未收敛，先停下交还以免空耗。）" : lastText)
    }

    /// 把工具调用签名归一:**实质为空的参数**(空对象 / 全空串 / 全 null)统一成 `name#EMPTY`,
    /// 让停滞检测能抓住"反复空/畸形调用同一工具"(任何弱脑通病,非特判);非空则保留原始 name#args 签名。
    nonisolated static func normalizedToolSignature(name: String, argsJSON: String) -> String {
        let trimmed = argsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let empty: Bool
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            empty = obj.isEmpty || obj.values.allSatisfy { v in
                if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if v is NSNull { return true }
                return false
            }
        } else {
            empty = trimmed.isEmpty || trimmed == "{}" || trimmed.lowercased() == "null"
        }
        return empty ? "\(name)#EMPTY" : "\(name)#\(argsJSON)"
    }

    /// 给一组**未执行就交还**的 tool_calls 补上合成 tool 结果,保持 OpenAI 协议良构(每个 tool_call 必有 tool 响应)。
    /// 用于停滞交还等"放弃执行本回合调用"的分支——避免悬空未应答调用导致续接时网关报错。
    private func appendSyntheticToolResults(for calls: [LingShuAgentToolCall], note: String) {
        for call in calls {
            messages.append(.init(role: .tool, content: note, toolCallID: call.id))
        }
    }

    /// 从阻塞工具的 arguments JSON 抽出问题文本(取 question 字段,缺则用原文)。
    static func extractQuestion(from argumentsJSON: String) -> String {
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let question = object["question"] as? String, !question.isEmpty {
            return question
        }
        return argumentsJSON
    }

    /// 阻塞工具返回给宿主 UI 的提示。自由问句直接给问题；结构化卡片则给 envelope，
    /// 由 State 层渲染表单/选项并在用户提交后 resume 原工具调用。
    static func blockedPrompt(for call: LingShuAgentToolCall) -> String {
        switch call.name {
        case "ask_form", "ask_choice":
            return LingShuHumanInputEnvelope(tool: call.name, argumentsJSON: call.argumentsJSON).encodedPrompt
        default:
            return extractQuestion(from: call.argumentsJSON)
        }
    }
}
