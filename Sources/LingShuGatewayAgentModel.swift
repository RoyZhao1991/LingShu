import Foundation

/// 真实模型适配器:让 agent 编排循环跑在真模型网关上(原生 tool_calls 出入)。
///
/// 把 `LingShuAgentSession` 的消息/工具 ↔ 网关类型互转,复用 `LingShuRemoteModelClient`
/// 的非流式 function-calling 请求。这就是「脚本大脑 → 真模型大脑」的切换件。
final class LingShuGatewayAgentModel: LingShuAgentModel, @unchecked Sendable {
    private let client: LingShuRemoteModelClient
    private let provider: String
    private let model: String
    private let endpoint: String
    private let protocolName: String
    private let apiKey: String
    private let temperature: Double
    private let timeout: TimeInterval
    /// 每步「边做边想」的旁白:模型在发起工具调用时附带的自然语言推理(剥 think 后)经此上报,
    /// 让执行流像 codex 一样可读(我观察到X→打算做Y→为什么)。@unchecked Sendable 持有。
    var onReasoning: (@Sendable (String) -> Void)?

    init(
        client: LingShuRemoteModelClient,
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        apiKey: String,
        temperature: Double,
        timeout: TimeInterval
    ) {
        self.client = client
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.protocolName = protocolName
        self.apiKey = apiKey
        self.temperature = temperature
        self.timeout = timeout
    }

    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
        let conversation = Self.sanitizeToolCallSequence(messages.map(Self.toModelMessage))
        let toolDefs = tools.map(Self.toToolDefinition)
        let request = LingShuRemoteModelRequest(
            provider: provider,
            model: model,
            endpoint: endpoint,
            protocolName: protocolName,
            apiKey: apiKey,
            systemPrompt: "",
            userPrompt: "",
            temperature: temperature,
            stream: false,
            timeout: timeout,
            continuationToken: nil,
            conversationMessages: conversation,
            tools: toolDefs
        )
        // 自愈:模型调用超时/瞬时网络抖动会恢复——重试(指数退避)而不是一超时就把整轮当"完成"中断。
        // 用户主动取消(CancellationError)立即让路,不重试。最多 3 次都失败才如实回报(不伪装成结果)。
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return .text("（本轮已被取消）") }
            do {
                let reply = try await client.send(request)
                // 前缀缓存可观测:本轮命中 + **累计命中率**(命中率掉=前缀被打乱,立刻看得见)。每次调用都记(含未命中,口径才准)。
                if let prompt = reply.promptTokens {
                    let snap = LingShuPrefixCacheMeter.shared.record(prompt: prompt, cached: reply.cachedTokens ?? 0)
                    lingShuControlLog("prefix-cache: 本轮 hit=\(reply.cachedTokens ?? 0)/\(prompt) | 累计命中率 \(snap.ratePercent)% (\(snap.totalCached)/\(snap.totalPrompt), \(snap.calls)次) | \(provider) \(model)")
                }
                if !reply.toolCalls.isEmpty {
                    // 边做边想:把模型发起动作时的旁白上报(供执行流像 codex 一样显示「分析→动作」)。
                    let aside = LingShuReasoningText.stripThinkTags(reply.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !aside.isEmpty { onReasoning?(aside) }
                    return .toolCalls(reply.toolCalls.map {
                        LingShuAgentToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.arguments)
                    })
                }
                // 剥掉 <think>…</think> 等推理标签,只留对用户的正文。
                return .text(LingShuReasoningText.stripThinkTags(reply.text))
            } catch is CancellationError {
                return .text("（本轮已被取消）")
            } catch {
                lastError = error
                lingShuControlLog("agent model error(尝试 \(attempt)/\(maxAttempts)): \(error) | endpoint=\(endpoint) provider=\(provider) model=\(model) keyLen=\(apiKey.count) msgs=\(messages.count) tools=\(tools.count)")
                // 4xx 客户端错误(消息结构/参数非法,**非** 429 限流)→ 重试也不会好,**绝不**当网络中断无限重刷:直接如实终止本轮。
                if case let LingShuModelGatewayError.requestFailed(code, body) = error, (400..<500).contains(code), code != 429 {
                    return .text("(本轮请求被模型服务端拒绝 HTTP \(code):\(body.prefix(160))。这是请求结构/参数问题,不是网络中断——我先停下这轮,不重试。)")
                }
                if attempt < maxAttempts {
                    // 退避:1.5s、3s——给瞬时超时/限流喘息,再原样重发同一上下文。
                    try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * attempt))
                }
            }
        }
        // 基础设施中断(非任务失败):重试耗尽 → 返回 .failed,循环据此 .interrupted 并保留上下文,等重连自动续跑。
        return .failed(reason: "模型调用连续 \(maxAttempts) 次未成功:\(lastError?.localizedDescription ?? "未知原因")。可能是主通道不可达或网络问题——已暂停,联网后自动接着跑。")
    }

    /// 流式应答:最终答复逐字经 `onTextDelta` 回调(进 UI 气泡 + 按句早读 TTS)。工具轮 content 基本为空、
    /// 不进气泡,只累积 tool_calls 后返回 .toolCalls。仅 chat/completions 形态真流式,其余回退非流式。
    func respondStreaming(messages: [LingShuAgentMessage], tools: [LingShuAgentTool], onTextDelta: @Sendable (String) async -> Void) async -> LingShuAgentModelResponse {
        guard client.supportsAgentStreaming(provider: provider, endpoint: endpoint, protocolName: protocolName) else {
            return await respond(messages: messages, tools: tools)
        }
        if Task.isCancelled { return .text("（本轮已被取消）") }
        let request = LingShuRemoteModelRequest(
            provider: provider, model: model, endpoint: endpoint, protocolName: protocolName,
            apiKey: apiKey, systemPrompt: "", userPrompt: "", temperature: temperature,
            stream: true, timeout: timeout, continuationToken: nil,
            conversationMessages: Self.sanitizeToolCallSequence(messages.map(Self.toModelMessage)), tools: tools.map(Self.toToolDefinition)
        )
        do {
            let reply = try await client.streamAgent(request, onContentDelta: onTextDelta)
            if let prompt = reply.promptTokens {
                let snap = LingShuPrefixCacheMeter.shared.record(prompt: prompt, cached: reply.cachedTokens ?? 0)
                lingShuControlLog("prefix-cache: 本轮 hit=\(reply.cachedTokens ?? 0)/\(prompt) (stream) | 累计命中率 \(snap.ratePercent)% (\(snap.totalCached)/\(snap.totalPrompt), \(snap.calls)次) | \(provider) \(model)")
            }
            if !reply.toolCalls.isEmpty {
                let aside = LingShuReasoningText.stripThinkTags(reply.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !aside.isEmpty { onReasoning?(aside) }
                return .toolCalls(reply.toolCalls.map {
                    LingShuAgentToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.arguments)
                })
            }
            return .text(LingShuReasoningText.stripThinkTags(reply.text))
        } catch is CancellationError {
            return .text("（本轮已被取消）")
        } catch {
            lingShuControlLog("agent stream error: \(error) | endpoint=\(endpoint) provider=\(provider) model=\(model)")
            // 4xx 客户端错误(结构/参数,非 429)→ 不当网络中断无限重刷,如实终止本轮。
            if case let LingShuModelGatewayError.requestFailed(code, body) = error, (400..<500).contains(code), code != 429 {
                return .text("(本轮请求被模型服务端拒绝 HTTP \(code):\(body.prefix(160))。这是请求结构/参数问题,不是网络中断——我先停下这轮,不重试。)")
            }
            // 其余(网络/网关/5xx/超时)当基础设施中断 → 循环 .interrupted → 挂起,重连后续跑。
            return .failed(reason: "流式连接中断:\(error.localizedDescription)。已暂停,联网后自动接着跑。")
        }
    }

    // MARK: - 类型互转

    /// **自愈消息结构**:OpenAI/DeepSeek 协议要求每个带 `tool_calls` 的 assistant 消息后,必须紧跟对应**每个 tool_call_id**的 tool 结果。
    /// 中途插话/续跑/历史裁剪等若让某次 tool_calls 没补齐结果(实测:发反馈时插到工具调用中间),严格服务端(DeepSeek)会
    /// 400 invalid_request,且被外层误判成"网络中断"无限重试刷屏。这里在发送前补齐:凡缺失结果的 tool_call_id 补一条占位 tool 消息。
    static func sanitizeToolCallSequence(_ messages: [LingShuModelMessage]) -> [LingShuModelMessage] {
        var result: [LingShuModelMessage] = []
        result.reserveCapacity(messages.count)
        var i = 0
        while i < messages.count {
            let m = messages[i]
            result.append(m)
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                var provided = Set<String>()
                var j = i + 1
                while j < messages.count, messages[j].role == "tool" {
                    result.append(messages[j])
                    if let id = messages[j].toolCallID { provided.insert(id) }
                    j += 1
                }
                for call in calls where !provided.contains(call.id) {
                    result.append(LingShuModelMessage(role: "tool",
                        content: "(该工具调用未补齐结果,占位以保证消息结构合法)", toolCalls: nil, toolCallID: call.id))
                }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    private static func toModelMessage(_ message: LingShuAgentMessage) -> LingShuModelMessage {
        LingShuModelMessage(
            role: message.role.rawValue,
            content: message.content,
            toolCalls: message.toolCalls.isEmpty ? nil : message.toolCalls.map {
                LingShuToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON)
            },
            toolCallID: message.toolCallID
        )
    }

    private static func toToolDefinition(_ tool: LingShuAgentTool) -> LingShuToolDefinition {
        let (properties, required) = parseSchema(tool.parametersJSON)
        return LingShuToolDefinition(
            name: tool.name,
            description: tool.description,
            properties: properties,
            required: required
        )
    }

    /// 把工具的 JSON schema 字符串解析成网关需要的 (properties, required)。
    private static func parseSchema(_ json: String) -> ([LingShuToolDefinition.Property], [String]) {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([], []) }
        let required = (object["required"] as? [String]) ?? []
        var props: [LingShuToolDefinition.Property] = []
        if let properties = object["properties"] as? [String: Any] {
            for (name, raw) in properties {
                let spec = raw as? [String: Any] ?? [:]
                props.append(.init(
                    name: name,
                    type: (spec["type"] as? String) ?? "string",
                    description: (spec["description"] as? String) ?? ""
                ))
            }
        }
        return (props, required)
    }
}
