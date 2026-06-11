import Foundation

enum LingShuModelConnectionKind: String, Equatable {
    case codexAuth = "Codex Auth"
    case apiKey = "API Key"
}

enum LingShuModelGatewayRequestFormat: String, Equatable {
    case codexBridge
    case responses
    case chatCompletions
    case anthropicMessages
    case hostAdapter
}

enum LingShuModelGatewayError: Error, Equatable {
    case codexAuthRequiresBridge
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

private struct LingShuAnthropicMessagesRequest: Codable, Equatable {
    var model: String
    var system: String
    var messages: [LingShuModelMessage]
    var maxTokens: Int
    var temperature: Double
    var stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case stream
    }
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
        apiKey: String,
        codexAuthStatus: String,
        codexAuthDetail: String
    ) -> LingShuModelGatewaySnapshot {
        let usesCodexAuth = provider == "Codex Auth"
        if usesCodexAuth {
            let isConnected = codexAuthStatus == "已登录"
            let status: String
            switch codexAuthStatus {
            case "已登录":
                status = "已连接：\(codexAuthDetail)"
            case "未检查":
                status = "主通道未检查"
            case "检查中":
                status = "主通道检查中"
            case "未登录":
                status = "主通道未接入"
            default:
                status = "主通道异常"
            }

            return .init(
                provider: provider,
                model: model,
                endpoint: endpoint,
                connectionKind: .codexAuth,
                isConnected: isConnected,
                statusText: status
            )
        }

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

        if normalizedProvider.contains("codex") || normalizedEndpoint.hasPrefix("codex://") {
            return .codexBridge
        }
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
        conversationMessages: [LingShuModelMessage] = []
    ) throws -> LingShuModelInvocationContract {
        let format = requestFormat(provider: provider, endpoint: endpoint, protocolName: protocolName)
        switch format {
        case .codexBridge:
            throw LingShuModelGatewayError.codexAuthRequiresBridge
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
            body = try encoder.encode(LingShuChatCompletionsRequest(
                model: model,
                messages: messages,
                temperature: temperature,
                stream: stream
            ))
        case .anthropicMessages:
            body = try encoder.encode(LingShuAnthropicMessagesRequest(
                model: model,
                system: systemPrompt,
                messages: messages.filter { $0.role != "system" },
                maxTokens: 4096,
                temperature: temperature,
                stream: stream
            ))
        case .codexBridge, .hostAdapter:
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
        case .codexBridge, .hostAdapter:
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
        case .codexBridge, .hostAdapter:
            return baseURL
        }
    }

    private func headers(
        for provider: String,
        apiKey: String
    ) -> [String: String] {
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
            guard !content.isEmpty else { return nil }
            return .init(role: role, content: content)
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
