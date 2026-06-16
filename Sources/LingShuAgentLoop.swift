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
actor LingShuAgentSession {
    let id: String
    let tools: [LingShuAgentTool]
    let model: any LingShuAgentModel
    let maxTurns: Int
    /// 阻塞工具名:模型调用这些工具即视为"卡住等外部输入"(默认 ask_user)。
    let blockingToolNames: Set<String>
    /// 上下文历史窗口上限(非系统消息条数)。0=不裁剪。常驻主会话设上限,杜绝旧任务无限堆积污染新任务
    /// (例:被问"做自我介绍 PPT"却把几轮前的「人工智能发展简史.pptx」当素材塞进去)。
    let maxHistoryMessages: Int
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

    init(
        id: String,
        system: String? = nil,
        initialMessages: [LingShuAgentMessage] = [],
        tools: [LingShuAgentTool],
        model: any LingShuAgentModel,
        maxTurns: Int = 40,   // 安全天花板(防失控),非目标预算;目标达成/卡住/停滞才是真正的停止位
        maxHistoryMessages: Int = 0,   // 0=不裁剪(短命子会话);常驻主会话传正数设窗口
        blockingToolNames: Set<String> = ["ask_user"]
    ) {
        self.id = id
        self.tools = tools
        self.model = model
        self.maxTurns = max(1, maxTurns)
        self.maxHistoryMessages = max(0, maxHistoryMessages)
        self.blockingToolNames = blockingToolNames
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
        pendingCorrection = nil   // 新回合不带上一回合可能残留的纠正
        consumePendingBriefings() // 子任务简报先入上下文(在用户新输入之前)——主线程信息同步
        trimHistoryIfNeeded()     // 在回合边界(无挂起工具调用)裁剪旧上下文,新输入永远保留
        messages.append(.init(role: .user, content: userText))
        return await runLoop()
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

    /// 续接:把外部给的答案回填到卡住的阻塞工具调用上,继续跑循环。
    func resume(_ answer: String) async -> LingShuAgentRunResult {
        guard let pending = pendingBlockToolCallID else {
            return await send(answer)   // 没在卡 → 当普通输入
        }
        messages.append(.init(role: .tool, content: answer, toolCallID: pending))
        pendingBlockToolCallID = nil
        return await runLoop()
    }

    /// 重连后续跑(断网恢复用):**不注入任何新消息**,直接接着跑循环——上下文停在中断前的良构状态,
    /// 重发的就是中断那一步的模型调用。`step` 重置=新的一段预算(与 send/resume 一致)。
    func continueLoop() async -> LingShuAgentRunResult {
        await runLoop()
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
        while step < maxTurns {   // maxTurns = 安全天花板,非目标停止位
            // 用户停止:真停(任务取消)→ 诚实交还,不假装收尾。
            if Task.isCancelled {
                return .maxTurnsReached(lastText: lastText.isEmpty ? "（已被用户停止）" : lastText)
            }
            // 回合边界采纳子任务简报(信息同步)+ 纠正(最高优先级 user 指令)。
            consumePendingBriefings()
            _ = consumePendingCorrection()
            step += 1
            turnsUsed += 1
            // 设了 delta 接收口(仅主会话)→ 走流式,最终答复逐字回调进气泡;否则非流式(子会话/自主/测试,零变更)。
            let response: LingShuAgentModelResponse
            if let sink = textDeltaSink {
                response = await model.respondStreaming(messages: messages, tools: tools, onTextDelta: sink)
            } else {
                response = await model.respond(messages: messages, tools: tools)
            }
            switch response {
            case .failed(let reason):
                // 基础设施中断(网络/网关不可达):**不收尾、不污染上下文**——绝不追加假的"调用失败"助手消息,
                // 让 messages 原样停在中断前的良构状态(上一步若是工具循环,tool 结果已补齐)。
                // 返回 .interrupted:上层据此把任务标"已暂停"并保留本会话,重连后 continueLoop() 重发这步模型调用即续上。
                return .interrupted(reason: reason)
            case .text(let text):
                messages.append(.init(role: .assistant, content: text))
                // 模型自认收尾,但用户刚下了纠正 → 不收尾,带着纠正继续(纠正跑偏的"假收尾")。
                if pendingCorrection != nil { continue }
                return .completed(text: text)
            case .toolCalls(let calls):
                guard !calls.isEmpty else {
                    return .completed(text: lastText)
                }
                messages.append(.init(role: .assistant, content: "", toolCalls: calls))
                // 阻塞工具:不执行,挂起等外部答案(human-in-the-loop)。
                if let blocking = calls.first(where: { blockingToolNames.contains($0.name) }) {
                    toolInvocations.append(blocking.name)
                    pendingBlockToolCallID = blocking.id
                    return .blocked(question: Self.extractQuestion(from: blocking.argumentsJSON))
                }
                // 停滞检测:连续 N 次发起完全相同(同名+同参)的工具调用 = 原地打转。
                let signature = calls.map { "\($0.name)#\($0.argumentsJSON)" }.joined(separator: "|")
                recentToolSignatures.append(signature)
                let tail = recentToolSignatures.suffix(Self.stuckRepeatThreshold)
                var pendingSteer: String? = nil
                if tail.count == Self.stuckRepeatThreshold, Set(tail).count == 1 {
                    let name = calls.first?.name ?? "同一动作"
                    if Self.optionalScaffoldTools.contains(name) {
                        // 卡在**可选脚手架工具**(如 update_plan)上:计划不是目标——绝不为它交还。
                        // 清掉签名史 + 执行完这次后注入纠偏,让模型跳过计划、直接用通用工具把任务做出来。
                        recentToolSignatures.removeAll()
                        pendingSteer = "【系统纠偏】update_plan 这步反复失败,但它只是**可选的计划工具、不是任务本身**。别再调用它了——直接用 write_file / run_command / web_search 等把用户真正要的事做出来,完成后给出结果。"
                    } else {
                        // 卡在**真任务动作**上才诚实交还,且给结果+原因+下一步,不是空喊"走不通"。
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
                for call in calls {
                    toolInvocations.append(call.name)
                    let result: String
                    if let tool = tools.first(where: { $0.name == call.name }) {
                        result = await tool.handler(call.argumentsJSON)
                    } else {
                        result = "错误:未知工具 \(call.name)"
                    }
                    lastText = result
                    messages.append(.init(role: .tool, content: result, toolCallID: call.id))
                }
                if let steer = pendingSteer {
                    messages.append(.init(role: .user, content: steer))
                }
                // 强制收尾(在工具执行后判,保证 messages 良构可被验收/resume):提示过仍空转 → 工作已完成,
                // 停止 maker 无限自测,**返回 .completed 交独立验收(checker)** 判定,而非无界空转或被撞顶误判异常。
                if sawMutation, turnsSinceMutation >= Self.overValidationForceAt {
                    return .completed(text: lastText.isEmpty ? "（工作已完成,产出物已落盘,停止重复验证,交付独立验收。）" : lastText)
                }
            }
        }
        // 撞到安全天花板(极少):同样诚实交还,不假装收尾。
        return .maxTurnsReached(lastText: lastText.isEmpty ? "（已推进很多步仍未收敛，先停下交还以免空耗。）" : lastText)
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
}
