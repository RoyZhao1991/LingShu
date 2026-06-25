import Foundation

enum LingShuModelConnectionKind: String, Equatable {
    case apiKey = "API Key"
}

enum LingShuModelGatewayRequestFormat: String, Equatable {
    case responses
    case chatCompletions
    case anthropicMessages
    case hostAdapter
}

enum LingShuModelGatewayError: Error, Equatable {
    case missingAPIKey
    case invalidEndpoint(String)
    case hostAdapterRequired(String)
    case requestFailed(Int, String)
    case emptyResponse
    case unsupportedResponse
}

struct LingShuModelGatewaySnapshot: Equatable {
    var provider: String
    var model: String
    var endpoint: String
    var connectionKind: LingShuModelConnectionKind
    var isConnected: Bool
    var statusText: String

    var engineLabel: String {
        "\(provider) / \(model)"
    }
}

struct LingShuModelInvocationContract: Equatable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data
    var format: LingShuModelGatewayRequestFormat
}

struct LingShuModelMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String
    /// 助手发起的工具调用（role=assistant 时）；原生 function-calling 用。
    var toolCalls: [LingShuToolCall]?
    /// 工具结果回传时对应的调用 id（role=tool 时）。
    var toolCallID: String?
    /// 原生多模态：内联图片的 data URL（data:image/png;base64,…）。非空时该消息走多模态 content 数组。
    var imageDataURLs: [String]?

    init(role: String, content: String, toolCalls: [LingShuToolCall]? = nil, toolCallID: String? = nil, imageDataURLs: [String]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.imageDataURLs = imageDataURLs
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        toolCalls = try? c.decodeIfPresent([LingShuToolCall].self, forKey: .toolCalls)
        toolCallID = try? c.decodeIfPresent(String.self, forKey: .toolCallID)
        imageDataURLs = nil   // 内联图片只走 wire 路径，不参与 Codable 持久化。
    }

    // 自定义编码：工具字段为空时不写进 JSON，保证非工具路径的请求体与改造前逐字节一致。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

private struct LingShuResponsesRequest: Codable, Equatable {
    var model: String
    var input: [LingShuModelMessage]
    var temperature: Double
    var stream: Bool
    var previousResponseID: String?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case temperature
        case stream
        case previousResponseID = "previous_response_id"
    }
}

private struct LingShuChatCompletionsRequest: Codable, Equatable {
    var model: String
    var messages: [LingShuModelMessage]
    var temperature: Double
    var stream: Bool
}

struct LingShuModelGateway {
    private let encoder: JSONEncoder

    init(encoder: JSONEncoder = JSONEncoder()) {
        self.encoder = encoder
    }

    func snapshot(
        provider: String,
        model: String,
        endpoint: String,
        apiKey: String
    ) -> LingShuModelGatewaySnapshot {
        let hasAPIKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canUseWithoutAPIKey = !requiresAPIKey(provider: provider, endpoint: endpoint)
        return .init(
            provider: provider,
            model: model,
            endpoint: endpoint,
            connectionKind: .apiKey,
            isConnected: hasAPIKey || canUseWithoutAPIKey,
            statusText: hasAPIKey ? "API Key 已配置，可发起真实请求" : (canUseWithoutAPIKey ? "本地/自托管通道可用" : "未连接")
        )
    }

    func requestFormat(
        provider: String,
        endpoint: String,
        protocolName: String
    ) -> LingShuModelGatewayRequestFormat {
        let normalizedProvider = provider.lowercased()
        let normalizedEndpoint = endpoint.lowercased()
        let normalizedProtocol = protocolName.lowercased()

        if normalizedEndpoint.hasPrefix("bedrock://")
            || normalizedEndpoint.hasPrefix("vertex://")
            || normalizedProtocol.contains("bedrock")
            || normalizedProtocol.contains("vertex") {
            return .hostAdapter
        }
        if (normalizedProvider.contains("anthropic")
            || normalizedProvider.contains("claude")
            || normalizedProtocol.contains("anthropic"))
            && !normalizedEndpoint.contains("openai") {
            return .anthropicMessages
        }
        if normalizedProtocol.contains("responses") || normalizedEndpoint.contains("/responses") {
            return .responses
        }

        return .chatCompletions
    }

    func makeInvocationContract(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        stream: Bool,
        continuationToken: String? = nil,
        conversationMessages: [LingShuModelMessage] = [],
        tools: [LingShuToolDefinition] = []
    ) throws -> LingShuModelInvocationContract {
        let format = requestFormat(provider: provider, endpoint: endpoint, protocolName: protocolName)
        switch format {
        case .hostAdapter:
            throw LingShuModelGatewayError.hostAdapterRequired(protocolName)
        case .responses, .chatCompletions, .anthropicMessages:
            break
        }

        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty || !requiresAPIKey(provider: provider, endpoint: endpoint) else {
            throw LingShuModelGatewayError.missingAPIKey
        }
        guard let baseURL = URL(string: endpoint),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            throw LingShuModelGatewayError.invalidEndpoint(endpoint)
        }

        let url = invocationURL(baseURL: baseURL, format: format)
        let body: Data
        let messages = normalizedMessages(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            conversationMessages: conversationMessages
        )
        switch format {
        case .responses:
            body = try encoder.encode(LingShuResponsesRequest(
                model: model,
                input: messages,
                temperature: temperature,
                stream: stream,
                previousResponseID: continuationToken?.nilIfBlank
            ))
        case .chatCompletions:
            let hasInlineImages = messages.contains { $0.imageDataURLs?.isEmpty == false }
            if tools.isEmpty && !hasInlineImages {
                body = try encoder.encode(LingShuChatCompletionsRequest(
                    model: model,
                    messages: messages,
                    temperature: temperature,
                    stream: stream
                ))
            } else {
                // 原生 function-calling / 多模态：tools 数组 + 可能带 tool_calls/tool_call_id/图片的消息，
                // 自由 JSON 结构用 JSONSerialization 构建（不动既有 Codable 路径，零回归）。
                var payload: [String: Any] = [
                    "model": model,
                    "messages": messages.map(Self.wireMessage),
                    "temperature": temperature,
                    "stream": stream
                ]
                if !tools.isEmpty {   // 仅多模态无工具时不带 tools 键，避免空数组惹某些网关。
                    payload["tools"] = tools.map { $0.wireObject() }
                }
                body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            }
        case .anthropicMessages:
            // Anthropic 必须显式打 cache_control 断点才会命中前缀缓存——按厂商策略自动启用（换模型自动选对）。
            body = try Self.anthropicMessagesBody(
                model: model,
                systemPrompt: systemPrompt,
                messages: messages.filter { $0.role != "system" },
                temperature: temperature,
                stream: stream,
                cache: LingShuPrefixCache.strategy(for: format)
            )
        case .hostAdapter:
            preconditionFailure("Non-HTTP model formats are handled before body construction.")
        }

        return .init(
            url: url,
            method: "POST",
            headers: headers(for: provider, apiKey: trimmedAPIKey),
            body: body,
            format: format
        )
    }

    /// Anthropic /messages 请求体。`cache=anthropicExplicit` 时给 **system + 最后一条消息**打 `cache_control` 断点
    /// → 命中前缀缓存（缓存读取约原价 1/10）。system 通常是最大、最稳定的前缀（身份+seed），最先值得缓存；
    /// 最后一条消息打断点会缓存"到上一轮为止"的整段对话前缀，多轮接力命中。其它策略退化为不带断点的等价请求体。
    /// 注：Anthropic 只认 user/assistant；OpenAI 形态的 tool_calls/tool 角色不在此发（工具回合走 Anthropic 原生形态是另一处缺口）。
    static func anthropicMessagesBody(
        model: String,
        systemPrompt: String,
        messages: [LingShuModelMessage],
        temperature: Double,
        stream: Bool,
        cache: LingShuPrefixCacheStrategy
    ) throws -> Data {
        let explicit = (cache == .anthropicExplicit)
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "temperature": temperature,
            "stream": stream
        ]
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            payload["system"] = explicit
                ? [LingShuPrefixCache.anthropicCachedTextBlock(systemPrompt)]
                : systemPrompt
        }
        let lastIndex = messages.indices.last
        payload["messages"] = messages.enumerated().map { idx, message -> [String: Any] in
            let role = (message.role == "assistant") ? "assistant" : "user"
            if explicit, idx == lastIndex {
                return ["role": role, "content": [LingShuPrefixCache.anthropicCachedTextBlock(message.content)]]
            }
            return ["role": role, "content": message.content]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// 把一条消息序列化成 OpenAI chat/completions 的 wire 对象（含 tool_calls / tool_call_id）。
    static func wireMessage(_ message: LingShuModelMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role]
        if let images = message.imageDataURLs, !images.isEmpty {
            // 原生多模态：content 是 [文字, 图片…] 数组（OpenAI / KIMI 通用）。
            var parts: [[String: Any]] = []
            if !message.content.isEmpty {
                parts.append(["type": "text", "text": message.content])
            }
            for url in images {
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            object["content"] = parts
        } else {
            object["content"] = message.content
        }
        if let calls = message.toolCalls, !calls.isEmpty {
            object["tool_calls"] = calls.map { call -> [String: Any] in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
            }
        }
        if let toolCallID = message.toolCallID {
            object["tool_call_id"] = toolCallID
        }
        return object
    }

    /// 从响应里解析原生工具调用（`choices[0].message.tool_calls`）。无则空数组。
    func decodeToolCalls(data: Data) -> [LingShuToolCall] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let rawCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return rawCalls.compactMap { raw in
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let id = (raw["id"] as? String) ?? UUID().uuidString
            let arguments = (function["arguments"] as? String) ?? "{}"
            return LingShuToolCall(id: id, name: name, arguments: arguments)
        }
    }

    func decodeStreamingTextDelta(line: String, format: LingShuModelGatewayRequestFormat) -> String? {
        let payload = streamingPayload(from: line)
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch format {
        case .responses:
            if let type = object["type"] as? String,
               type == "response.output_text.delta",
               let delta = object["delta"] as? String {
                return delta.nilIfBlank
            }
            return extractText(from: object)?.nilIfBlank
        case .chatCompletions:
            return extractText(from: object)?.nilIfBlank
        case .anthropicMessages:
            if let type = object["type"] as? String,
               type == "content_block_delta",
               let delta = object["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return text.nilIfBlank
            }
            return extractText(from: object)?.nilIfBlank
        case .hostAdapter:
            return nil
        }
    }

    func decodeStreamingContinuationToken(line: String, format: LingShuModelGatewayRequestFormat) -> String? {
        guard format == .responses else { return nil }
        let payload = streamingPayload(from: line)
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let response = object["response"] as? [String: Any],
           let id = response["id"] as? String {
            return id.nilIfBlank
        }
        if let id = object["id"] as? String {
            return id.nilIfBlank
        }
        return nil
    }

    func makeURLRequest(
        for contract: LingShuModelInvocationContract
    ) -> URLRequest {
        var request = URLRequest(url: contract.url)
        request.httpMethod = contract.method
        request.httpBody = contract.body
        request.timeoutInterval = 180
        for (key, value) in contract.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    func decodeTextResponse(data: Data, statusCode: Int) throws -> String {
        let rawText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (200..<300).contains(statusCode) else {
            throw LingShuModelGatewayError.requestFailed(statusCode, rawText)
        }
        guard !data.isEmpty else {
            throw LingShuModelGatewayError.emptyResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            if rawText.isEmpty {
                throw LingShuModelGatewayError.emptyResponse
            }
            return rawText
        }

        if let object = json as? [String: Any],
           let text = extractText(from: object)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        if !rawText.isEmpty {
            return rawText
        }
        throw LingShuModelGatewayError.unsupportedResponse
    }

    private func invocationURL(
        baseURL: URL,
        format: LingShuModelGatewayRequestFormat
    ) -> URL {
        let path = baseURL.path.lowercased()
        switch format {
        case .responses:
            return path.hasSuffix("/responses") ? baseURL : baseURL.appendingPathComponent("responses")
        case .chatCompletions:
            return path.hasSuffix("/chat/completions") ? baseURL : baseURL.appendingPathComponent("chat/completions")
        case .anthropicMessages:
            return path.hasSuffix("/messages") ? baseURL : baseURL.appendingPathComponent("messages")
        case .hostAdapter:
            return baseURL
        }
    }

    private func headers(
        for provider: String,
        apiKey: String
    ) -> [String: String] {
        if provider.localizedCaseInsensitiveContains("数据网络")
            || provider.lowercased().contains("datanet") {
            return [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-Model-Token": apiKey
            ].filter { !$0.value.isEmpty }
        }

        if provider.localizedCaseInsensitiveContains("Anthropic")
            || provider.localizedCaseInsensitiveContains("Claude") {
            return [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01"
            ].filter { !$0.value.isEmpty }
        }

        if provider.localizedCaseInsensitiveContains("Azure") {
            return [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "api-key": apiKey
            ].filter { !$0.value.isEmpty }
        }

        return [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer \(apiKey)"
        ].filter { !$0.value.isEmpty && $0.value != "Bearer " }
    }

    private func requiresAPIKey(provider: String, endpoint: String) -> Bool {
        let normalizedProvider = provider.lowercased()
        if normalizedProvider.contains("ollama")
            || normalizedProvider.contains("lm studio")
            || normalizedProvider.contains("vllm") {
            return false
        }

        guard let url = URL(string: endpoint), let host = url.host?.lowercased() else {
            return true
        }
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    private func extractText(from object: [String: Any]) -> String? {
        if let outputText = object["output_text"] as? String {
            return outputText
        }
        if let text = object["text"] as? String {
            return text
        }
        if let response = object["response"] as? String {
            return response
        }
        if let message = object["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                return content
            }
            if let content = message["content"] as? [[String: Any]] {
                return textFromContentBlocks(content)
            }
        }
        if let content = object["content"] as? [[String: Any]] {
            return textFromContentBlocks(content)
        }
        if let choices = object["choices"] as? [[String: Any]] {
            let texts = choices.compactMap { choice -> String? in
                if let message = choice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    return content
                }
                if let text = choice["text"] as? String {
                    return text
                }
                if let delta = choice["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    return content
                }
                return nil
            }
            return texts.joined(separator: "\n").nilIfBlank
        }
        if let output = object["output"] as? [[String: Any]] {
            let texts = output.compactMap { item -> String? in
                if let content = item["content"] as? [[String: Any]] {
                    return textFromContentBlocks(content)
                }
                if let text = item["text"] as? String {
                    return text
                }
                return nil
            }
            return texts.joined(separator: "\n").nilIfBlank
        }
        return nil
    }

    private func normalizedMessages(
        systemPrompt: String,
        userPrompt: String,
        conversationMessages: [LingShuModelMessage]
    ) -> [LingShuModelMessage] {
        let cleanedConversation = conversationMessages.compactMap { message -> LingShuModelMessage? in
            let role = normalizedRole(message.role)
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 带工具负载 / 内联图片的消息即便正文为空也必须保留，否则多轮会话/多模态会被掐断。
            let hasToolPayload = (message.toolCalls?.isEmpty == false) || (message.toolCallID != nil)
            let hasImages = message.imageDataURLs?.isEmpty == false
            guard !content.isEmpty || hasToolPayload || hasImages else { return nil }
            return .init(role: role, content: message.content, toolCalls: message.toolCalls, toolCallID: message.toolCallID, imageDataURLs: message.imageDataURLs)
        }

        if !cleanedConversation.isEmpty {
            let hasSystem = cleanedConversation.contains { $0.role == "system" }
            return hasSystem
                ? cleanedConversation
                : [.init(role: "system", content: systemPrompt)] + cleanedConversation
        }

        return [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: userPrompt)
        ]
    }

    private func normalizedRole(_ role: String) -> String {
        let normalized = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "system", "assistant", "user", "tool":
            return normalized
        default:
            return "user"
        }
    }

    private func streamingPayload(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func textFromContentBlocks(_ blocks: [[String: Any]]) -> String? {
        blocks.compactMap { block -> String? in
            if let text = block["text"] as? String {
                return text
            }
            if let text = block["output_text"] as? String {
                return text
            }
            if let nested = block["content"] as? String {
                return nested
            }
            return nil
        }
        .joined(separator: "\n")
        .nilIfBlank
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
