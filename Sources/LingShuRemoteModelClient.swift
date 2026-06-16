import Foundation

struct LingShuRemoteModelRequest: Equatable {
    var provider: String
    var model: String
    var endpoint: String
    var protocolName: String
    var apiKey: String
    var systemPrompt: String
    var userPrompt: String
    var temperature: Double
    var stream: Bool
    var timeout: TimeInterval
    var continuationToken: String?
    var conversationMessages: [LingShuModelMessage] = []
    /// 原生 function-calling 工具定义；非空时随请求下发 `tools`（仅 chat/completions 生效）。
    var tools: [LingShuToolDefinition] = []
}

struct LingShuRemoteModelReply: Equatable {
    var text: String
    var statusCode: Int
    var format: LingShuModelGatewayRequestFormat
    var continuationToken: String?
    /// usage.total_tokens（网关计量）。流式响应通常不携带，可能为 nil。
    var totalTokens: Int?
    /// 输入 token 总数（prompt_tokens / input_tokens）。
    var promptTokens: Int?
    /// 命中前缀缓存的输入 token 数（跨厂商口径，见 LingShuPrefixCache.parseCacheUsage）。命中越高越省钱。
    var cachedTokens: Int?
    /// 模型返回的原生工具调用（choices[0].message.tool_calls）。无则空数组。
    var toolCalls: [LingShuToolCall] = []
}

struct LingShuRemoteModelClient {
    private let gateway: LingShuModelGateway
    private let session: URLSession

    init(
        gateway: LingShuModelGateway = LingShuModelGateway(),
        session: URLSession = .shared
    ) {
        self.gateway = gateway
        self.session = session
    }

    func send(_ request: LingShuRemoteModelRequest) async throws -> LingShuRemoteModelReply {
        let contract = try gateway.makeInvocationContract(
            provider: request.provider,
            model: request.model,
            endpoint: request.endpoint,
            protocolName: request.protocolName,
            apiKey: request.apiKey,
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            temperature: request.temperature,
            stream: request.stream,
            continuationToken: request.continuationToken,
            conversationMessages: request.conversationMessages,
            tools: request.tools
        )
        var urlRequest = gateway.makeURLRequest(for: contract)
        urlRequest.timeoutInterval = request.timeout

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LingShuModelGatewayError.requestFailed(-1, "模型网关返回了非 HTTP 响应。")
        }

        let toolCalls = gateway.decodeToolCalls(data: data)
        // 工具调用回合常常没有正文，只有 tool_calls——此时 decodeTextResponse 会抛空响应，
        // 但这是合法状态，不该当错误，给空正文即可。
        let text: String
        if toolCalls.isEmpty {
            text = try gateway.decodeTextResponse(data: data, statusCode: httpResponse.statusCode)
        } else {
            text = (try? gateway.decodeTextResponse(data: data, statusCode: httpResponse.statusCode)) ?? ""
        }
        let usage = Self.decodeUsage(data: data)
        return .init(
            text: text,
            statusCode: httpResponse.statusCode,
            format: contract.format,
            continuationToken: Self.decodeContinuationToken(data: data, format: contract.format),
            totalTokens: usage.total,
            promptTokens: usage.prompt,
            cachedTokens: usage.cached,
            toolCalls: toolCalls
        )
    }

    /// agent 真流式是否支持:只有 OpenAI chat/completions 形态(DeepSeek/通义/Kimi/MiniMax/数据网关…)走真流式;
    /// OpenAI Responses / Anthropic 的事件流与工具调用形态不同,交回退非流式(避免误解析 tool_calls)。
    func supportsAgentStreaming(provider: String, endpoint: String, protocolName: String) -> Bool {
        gateway.requestFormat(provider: provider, endpoint: endpoint, protocolName: protocolName) == .chatCompletions
    }

    /// agent 流式调用(SSE):逐块解析 `delta.content`(回调 `onContentDelta`,逐字进 UI)+ 累积 `delta.tool_calls` 分片
    /// + 末块 usage(含前缀缓存命中)。**单次尝试不内部重试**——中途断由上层走"断网挂起→重连续跑",避免重试导致气泡重复。
    func streamAgent(_ request: LingShuRemoteModelRequest, onContentDelta: @Sendable (String) async -> Void) async throws -> LingShuRemoteModelReply {
        let contract = try gateway.makeInvocationContract(
            provider: request.provider, model: request.model, endpoint: request.endpoint,
            protocolName: request.protocolName, apiKey: request.apiKey,
            systemPrompt: request.systemPrompt, userPrompt: request.userPrompt,
            temperature: request.temperature, stream: true,
            continuationToken: request.continuationToken,
            conversationMessages: request.conversationMessages, tools: request.tools
        )
        var urlRequest = gateway.makeURLRequest(for: contract)
        urlRequest.timeoutInterval = request.timeout
        // 让流式也回 usage(DeepSeek/OpenAI 支持 stream_options;不支持的网关忽略无害)→ 保留前缀缓存命中可观测。
        if let body = urlRequest.httpBody,
           var obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            obj["stream_options"] = ["include_usage": true]
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LingShuModelGatewayError.requestFailed(-1, "模型网关返回了非 HTTP 响应。")
        }

        // ① 协议层解析器(按 format 适配:chat / responses / anthropic)——SSE 行 → 结构化增量。
        // ② 模型层 think 解析器(按 provider/model 适配:M3 内联 <think> 状态机 / 直通)——正文里实时剥思维链。
        let chunkParser = LingShuStreamChunkParsers.parser(for: contract.format)
        let thinkParser = LingShuModelReplyAdapters.adapter(provider: request.provider, model: request.model).makeStreamParser()

        var accumulated = ""
        var rawBody = ""
        var toolAccum: [Int: (id: String, name: String, args: String)] = [:]
        var usageObject: [String: Any]?

        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }
            rawBody += line + "\n"
            guard let chunk = chunkParser.parse(line: line) else { continue }
            if let usage = chunk.usage { usageObject = usage }
            // 正文增量经模型层 think 解析器:只把**用户可见正文**逐字进气泡(M3 等内联 <think> 实时剥掉,不污染气泡)。
            if !chunk.contentDelta.isEmpty {
                let event = thinkParser.ingest(chunk.contentDelta)
                if !event.contentDelta.isEmpty {
                    accumulated += event.contentDelta
                    await onContentDelta(event.contentDelta)
                }
                // event.reasoningDelta(内联 think)与 chunk.reasoningDelta(reasoning_content 字段)都是思维链,不进正文气泡。
            }
            // 工具调用分片:按 index 累积 id/name + 拼接 arguments。
            for delta in chunk.toolCallDeltas {
                var entry = toolAccum[delta.index] ?? ("", "", "")
                if let id = delta.id, !id.isEmpty { entry.id = id }
                if let name = delta.name, !name.isEmpty { entry.name = name }
                if let args = delta.argumentsFragment { entry.args += args }
                toolAccum[delta.index] = entry
            }
            if chunk.done { break }
        }
        // think 解析器收尾:排空缓冲里残留的正文(标签状态机可能留了尾巴)。
        let tail = thinkParser.finish()
        if !tail.contentDelta.isEmpty {
            accumulated += tail.contentDelta
            await onContentDelta(tail.contentDelta)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LingShuModelGatewayError.requestFailed(httpResponse.statusCode, rawBody)
        }

        let toolCalls = toolAccum.sorted { $0.key < $1.key }.compactMap { _, value -> LingShuToolCall? in
            guard !value.name.isEmpty else { return nil }
            return LingShuToolCall(id: value.id.isEmpty ? UUID().uuidString : value.id, name: value.name, arguments: value.args.isEmpty ? "{}" : value.args)
        }
        let cache = usageObject.map { LingShuPrefixCache.parseCacheUsage($0) } ?? (promptTokens: nil, cachedTokens: nil)
        return .init(
            text: accumulated,
            statusCode: httpResponse.statusCode,
            format: .chatCompletions,
            continuationToken: nil,
            totalTokens: usageObject?["total_tokens"] as? Int,
            promptTokens: cache.promptTokens,
            cachedTokens: cache.cachedTokens,
            toolCalls: toolCalls
        )
    }

    @MainActor
    func stream(
        _ request: LingShuRemoteModelRequest,
        onDelta: @escaping (String) -> Void,
        onHeartbeat: (() -> Void)? = nil
    ) async throws -> LingShuRemoteModelReply {
        let contract = try gateway.makeInvocationContract(
            provider: request.provider,
            model: request.model,
            endpoint: request.endpoint,
            protocolName: request.protocolName,
            apiKey: request.apiKey,
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            temperature: request.temperature,
            stream: true,
            continuationToken: request.continuationToken,
            conversationMessages: request.conversationMessages
        )
        var urlRequest = gateway.makeURLRequest(for: contract)
        urlRequest.timeoutInterval = request.timeout

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LingShuModelGatewayError.requestFailed(-1, "模型网关返回了非 HTTP 响应。")
        }

        var accumulated = ""
        var rawBody = ""
        var continuationToken: String?

        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }
            onHeartbeat?()
            rawBody += line
            rawBody += "\n"

            if let token = gateway.decodeStreamingContinuationToken(line: line, format: contract.format) {
                continuationToken = token
            }

            if let delta = gateway.decodeStreamingTextDelta(line: line, format: contract.format), !delta.isEmpty {
                accumulated += delta
                onDelta(delta)
            }
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LingShuModelGatewayError.requestFailed(httpResponse.statusCode, rawBody)
        }

        let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return .init(
                text: text,
                statusCode: httpResponse.statusCode,
                format: contract.format,
                continuationToken: continuationToken
            )
        }

        let fallbackData = Data(rawBody.utf8)
        return .init(
            text: try gateway.decodeTextResponse(data: fallbackData, statusCode: httpResponse.statusCode),
            statusCode: httpResponse.statusCode,
            format: contract.format,
            continuationToken: continuationToken ?? Self.decodeContinuationToken(data: fallbackData, format: contract.format),
            totalTokens: Self.decodeTotalTokens(data: fallbackData)
        )
    }

    static func decodeTotalTokens(data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }
        return usage["total_tokens"] as? Int
    }

    /// 解析整段 usage：总 token + 输入 token + 命中前缀缓存的 token（跨厂商，供用量/缓存命中可观测）。
    static func decodeUsage(data: Data) -> (total: Int?, prompt: Int?, cached: Int?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return (nil, nil, nil)
        }
        let cache = LingShuPrefixCache.parseCacheUsage(usage)
        return (usage["total_tokens"] as? Int, cache.promptTokens, cache.cachedTokens)
    }

    private static func decodeContinuationToken(
        data: Data,
        format: LingShuModelGatewayRequestFormat
    ) -> String? {
        guard format == .responses,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            return nil
        }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
