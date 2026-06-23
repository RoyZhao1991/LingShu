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
    private let maxAttempts: Int
    /// 每步「边做边想」的旁白:模型在发起工具调用时附带的自然语言推理(剥 think 后)经此上报,
    /// 让执行流像 codex 一样可读(我观察到X→打算做Y→为什么)。@unchecked Sendable 持有。
    var onReasoning: (@Sendable (String) -> Void)?

    /// #1·模型通道续接状态(锁保护):上回合会话签名 + 上回合网关返回的原生续接 id。
    /// 据此判"本回合是否干净追加",决定续接模式(改写过历史则降级 prefixStable),并在 native 模式带上 id。
    private let channelLock = NSLock()
    private var lastSignature: [String] = []
    private var lastResponseId: String?

    /// 算本回合该带的续接 token + 本回合签名(供成功后回写)。默认 provider(无状态/前缀缓存)→ nil,行为零变更。
    private func continuationPlan(for messages: [LingShuAgentMessage]) -> (token: String?, signature: [String]) {
        let sig = LingShuModelChannelStrategy.signature(messages)
        channelLock.lock(); let prev = lastSignature; let lastId = lastResponseId; channelLock.unlock()
        let clean = LingShuModelChannelStrategy.isCleanContinuation(previous: prev, current: sig)
        let mode = LingShuModelChannelStrategy.mode(provider: provider, didRewriteContext: !clean)
        return (LingShuModelChannelStrategy.continuationToken(mode: mode, lastResponseId: lastId), sig)
    }
    /// 成功收到响应后回写:更新签名 + 捕获网关返回的原生续接 id(供下回合 native 链上)。
    private func recordChannel(signature: [String], replyToken: String?) {
        channelLock.lock()
        lastSignature = signature
        if let t = replyToken, !t.isEmpty { lastResponseId = t }
        channelLock.unlock()
    }

    init(
        client: LingShuRemoteModelClient,
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        apiKey: String,
        temperature: Double,
        timeout: TimeInterval,
        maxAttempts: Int = 3
    ) {
        self.client = client
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.protocolName = protocolName
        self.apiKey = apiKey
        self.temperature = temperature
        self.timeout = timeout
        self.maxAttempts = max(1, maxAttempts)
    }

    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
        let conversation = Self.sanitizeToolCallSequence(messages.map(Self.toModelMessage))
        let toolDefs = tools.map(Self.toToolDefinition)
        let plan = continuationPlan(for: messages)   // #1:原生续接(支持的通道+干净追加)或 nil(无状态/已改写,行为零变更)
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
            continuationToken: plan.token,
            conversationMessages: conversation,
            tools: toolDefs
        )
        // 自愈:模型调用超时/瞬时网络抖动会恢复——重试(指数退避)而不是一超时就把整轮当"完成"中断。
        // 用户主动取消(CancellationError)立即让路,不重试。最多 3 次都失败才如实回报(不伪装成结果)。
        let maxAttempts = self.maxAttempts
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return .text("（本轮已被取消）") }
            do {
                let reply = try await client.send(request)
                recordChannel(signature: plan.signature, replyToken: reply.continuationToken)   // #1:捕获原生续接 id 供下回合链上
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
        let plan = continuationPlan(for: messages)   // #1:同 respond,原生续接或 nil
        let request = LingShuRemoteModelRequest(
            provider: provider, model: model, endpoint: endpoint, protocolName: protocolName,
            apiKey: apiKey, systemPrompt: "", userPrompt: "", temperature: temperature,
            stream: true, timeout: timeout, continuationToken: plan.token,
            conversationMessages: Self.sanitizeToolCallSequence(messages.map(Self.toModelMessage)), tools: tools.map(Self.toToolDefinition)
        )
        do {
            let reply = try await client.streamAgent(request, onContentDelta: onTextDelta)
            recordChannel(signature: plan.signature, replyToken: reply.continuationToken)
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

    /// **自愈消息结构(发送前最后一道良构闸,2026-06-21 补双向)**:OpenAI/DeepSeek 协议要求
    /// ① 每个带 `tool_calls` 的 assistant 后必须紧跟对应**每个 tool_call_id**的 tool 结果;
    /// ② 每条 `tool` 结果必须对应某个**更早 assistant 声明过的** tool_call_id(否则 400「tool must follow tool_calls」)。
    /// 中途插话/硬取消/续跑/历史裁剪/seeding 都可能破坏这两条。这里在序列化前一次修齐:
    /// **缺结果的 tool_call → 补占位**;**孤儿 tool 结果(无对应声明)→ 丢弃**。让任何来源的消息数组都不会把 400 发出去。
    /// (架网在会话层校验,这里是序列化边界的兜底闸——堵住"会话层看着合法、但取消/seeding 引入的孤儿溜到网关"的漏检。)
    static func sanitizeToolCallSequence(_ messages: [LingShuModelMessage]) -> [LingShuModelMessage] {
        var result: [LingShuModelMessage] = []
        result.reserveCapacity(messages.count)
        var declared = Set<String>()   // 至此所有 assistant 声明过的 tool_call id
        var i = 0
        while i < messages.count {
            let m = messages[i]
            // ② 孤儿 tool 结果:toolCallID 没被任何更早的 assistant tool_calls 声明 → 丢弃。
            if m.role == "tool" {
                if let id = m.toolCallID, declared.contains(id) { result.append(m) }
                i += 1
                continue
            }
            result.append(m)
            guard m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty else { i += 1; continue }
            calls.forEach { declared.insert($0.id) }
            // ① 收紧随后的 tool 结果(只收已声明的;紧跟的孤儿也丢),缺的补占位。
            var provided = Set<String>()
            var j = i + 1
            while j < messages.count, messages[j].role == "tool" {
                let tm = messages[j]
                if let id = tm.toolCallID, declared.contains(id) {
                    result.append(tm); provided.insert(id)
                }
                j += 1
            }
            for call in calls where !provided.contains(call.id) {
                result.append(LingShuModelMessage(role: "tool",
                    content: "(该工具调用未补齐结果,占位以保证消息结构合法)", toolCalls: nil, toolCallID: call.id))
            }
            i = j
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
