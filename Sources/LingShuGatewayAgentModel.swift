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
        let conversation = messages.map(Self.toModelMessage)
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
                if !reply.toolCalls.isEmpty {
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
                if attempt < maxAttempts {
                    // 退避:1.5s、3s——给瞬时超时/限流喘息,再原样重发同一上下文。
                    try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * attempt))
                }
            }
        }
        return .text("（模型调用连续 \(maxAttempts) 次未成功:\(lastError?.localizedDescription ?? "未知原因")。已重试并退避,仍未恢复——可能是主通道不可达或网络问题,请检查后让我继续。）")
    }

    // MARK: - 类型互转

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
