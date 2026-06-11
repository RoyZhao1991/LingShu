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
}

struct LingShuRemoteModelReply: Equatable {
    var text: String
    var statusCode: Int
    var format: LingShuModelGatewayRequestFormat
    var continuationToken: String?
    /// usage.total_tokens（网关计量）。流式响应通常不携带，可能为 nil。
    var totalTokens: Int?
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
            conversationMessages: request.conversationMessages
        )
        var urlRequest = gateway.makeURLRequest(for: contract)
        urlRequest.timeoutInterval = request.timeout

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LingShuModelGatewayError.requestFailed(-1, "模型网关返回了非 HTTP 响应。")
        }

        return .init(
            text: try gateway.decodeTextResponse(data: data, statusCode: httpResponse.statusCode),
            statusCode: httpResponse.statusCode,
            format: contract.format,
            continuationToken: Self.decodeContinuationToken(data: data, format: contract.format),
            totalTokens: Self.decodeTotalTokens(data: data)
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
