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

/// 模型一轮的产出:要么要求调用工具,要么给出最终文本。
enum LingShuAgentModelResponse: Sendable {
    case toolCalls([LingShuAgentToolCall])
    case text(String)
}

/// 编排循环依赖的模型接口(注入,便于真实网关与 mock 替换)。
protocol LingShuAgentModel: Sendable {
    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse
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
}

/// 一条隔离会话 = 一条任务线程的上下文与循环。多会话并发即多任务并行(配合有界并发管理器)。
actor LingShuAgentSession {
    let id: String
    let tools: [LingShuAgentTool]
    let model: any LingShuAgentModel
    let maxTurns: Int
    /// 阻塞工具名:模型调用这些工具即视为"卡住等外部输入"(默认 ask_user)。
    let blockingToolNames: Set<String>
    private(set) var messages: [LingShuAgentMessage]
    private(set) var turnsUsed = 0
    /// 按序记录工具调用名,便于可观测与测试。
    private(set) var toolInvocations: [String] = []
    /// 卡住时挂起的阻塞工具调用 id(供 resume 回填答案)。
    private var pendingBlockToolCallID: String?

    init(
        id: String,
        system: String? = nil,
        initialMessages: [LingShuAgentMessage] = [],
        tools: [LingShuAgentTool],
        model: any LingShuAgentModel,
        maxTurns: Int = 12,
        blockingToolNames: Set<String> = ["ask_user"]
    ) {
        self.id = id
        self.tools = tools
        self.model = model
        self.maxTurns = max(1, maxTurns)
        self.blockingToolNames = blockingToolNames
        var seeded: [LingShuAgentMessage] = []
        if let system { seeded.append(.init(role: .system, content: system)) }
        seeded.append(contentsOf: initialMessages)   // 跨重启续上:历史对话 seed 进上下文
        self.messages = seeded
    }

    var isBlocked: Bool { pendingBlockToolCallID != nil }

    /// 投入一条用户输入,跑完整循环直到模型收尾、卡住或到轮次上限。
    func send(_ userText: String) async -> LingShuAgentRunResult {
        messages.append(.init(role: .user, content: userText))
        return await runLoop()
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

    private func runLoop() async -> LingShuAgentRunResult {
        var lastText = ""
        for _ in 0..<maxTurns {
            turnsUsed += 1
            let response = await model.respond(messages: messages, tools: tools)
            switch response {
            case .text(let text):
                messages.append(.init(role: .assistant, content: text))
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
            }
        }
        return .maxTurnsReached(lastText: lastText)
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
