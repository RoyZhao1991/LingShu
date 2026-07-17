import Foundation

public struct LingShuCLIConfiguration: Sendable {
    public var endpoint: URL
    public var token: String?
    public var pollInterval: TimeInterval
    public var timeout: TimeInterval
    public var autoLaunchApp: Bool

    public init(
        endpoint: URL,
        token: String? = nil,
        pollInterval: TimeInterval = 0.5,
        timeout: TimeInterval = 900,
        autoLaunchApp: Bool = true
    ) {
        self.endpoint = endpoint
        self.token = token
        self.pollInterval = max(0.1, pollInterval)
        self.timeout = max(1, timeout)
        self.autoLaunchApp = autoLaunchApp
    }

    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let port = UInt16(environment["LINGSHU_MCP_PORT"] ?? "") ?? 8917
        let endpoint = URL(string: environment["LINGSHU_MCP_URL"] ?? "http://127.0.0.1:\(port)/mcp")!
        return .init(
            endpoint: endpoint,
            token: environment["LINGSHU_MCP_TOKEN"],
            pollInterval: TimeInterval(environment["LINGSHU_CLI_POLL_INTERVAL"] ?? "") ?? 0.5,
            timeout: TimeInterval(environment["LINGSHU_CLI_TIMEOUT"] ?? "") ?? 900,
            autoLaunchApp: environment["LINGSHU_CLI_NO_LAUNCH"] != "1"
        )
    }
}

public struct LingShuCLIMaterial: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var value: String
    public var mimeType: String?
}

public struct LingShuCLIOption: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var detail: String
    public var value: String
}

public struct LingShuCLIHumanInteraction: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var prompt: String
    public var options: [LingShuCLIOption]
    public var materials: [LingShuCLIMaterial]
}

public struct LingShuCLIResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case completed
        case needsUserAction = "needs_user_action"
        case failed
        case timedOut = "timed_out"
    }

    public var status: Status
    public var reply: String
    public var recordID: String
    public var messageID: String
    public var interaction: LingShuCLIHumanInteraction?

    public init(
        status: Status,
        reply: String = "",
        recordID: String = "",
        messageID: String = "",
        interaction: LingShuCLIHumanInteraction? = nil
    ) {
        self.status = status
        self.reply = reply
        self.recordID = recordID
        self.messageID = messageID
        self.interaction = interaction
    }
}

public enum LingShuCLIError: Error, CustomStringConvertible, Sendable {
    case appUnavailable(String)
    case invalidResponse(String)
    case remote(String)

    public var description: String {
        switch self {
        case .appUnavailable(let detail):
            "LingShu is not reachable. Open the app and try again. \(detail)"
        case .invalidResponse(let detail):
            "LingShu returned an invalid response. \(detail)"
        case .remote(let detail):
            detail
        }
    }
}

public final class LingShuCLIClient: @unchecked Sendable {
    private let configuration: LingShuCLIConfiguration
    private let session: URLSession

    public init(configuration: LingShuCLIConfiguration = .environment(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func ask(_ prompt: String, timeout: TimeInterval? = nil) async throws -> LingShuCLIResult {
        try await ensureAvailable()
        let submitted = try await callTool("lingshu_send_prompt", arguments: ["text": prompt, "source": "typed"])
        return await waitForReply(
            assistantMessageID: Self.string(submitted["assistantMessageId"]),
            recordID: Self.string(submitted["recordId"]),
            timeout: timeout ?? configuration.timeout
        )
    }

    public func answer(messageID: String, answer: String, timeout: TimeInterval? = nil) async throws -> LingShuCLIResult {
        try await ensureAvailable()
        let chat = try? await callTool("lingshu_get_chat", arguments: ["limit": 200])
        let baselineText = ((chat?["messages"] as? [[String: Any]]) ?? [])
            .last(where: { Self.string($0["id"]) == messageID })
            .map { Self.string($0["text"]) }
        let submitted = try await callTool(
            "lingshu_submit_human_interaction",
            arguments: ["messageId": messageID, "answer": answer]
        )
        return await waitForReply(
            assistantMessageID: messageID,
            recordID: Self.string(submitted["recordId"]),
            timeout: timeout ?? configuration.timeout,
            continuationBaselineText: baselineText
        )
    }

    public func status() async throws -> [String: Any] {
        try await ensureAvailable()
        return try await callTool("lingshu_status", arguments: [:])
    }

    public func stop() async throws -> [String: Any] {
        try await ensureAvailable()
        return try await callTool("lingshu_stop", arguments: [:])
    }

    public func ensureAvailable() async throws {
        if await healthCheck() { return }
        guard configuration.autoLaunchApp else {
            throw LingShuCLIError.appUnavailable("Auto-launch is disabled by LINGSHU_CLI_NO_LAUNCH=1.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "com.zhaoroy.LingShu"]
        try? process.run()
        process.waitUntilExit()

        for _ in 0..<40 {
            if await healthCheck() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LingShuCLIError.appUnavailable("The local control service did not become ready at \(configuration.endpoint.absoluteString).")
    }

    private func waitForReply(
        assistantMessageID: String,
        recordID: String,
        timeout: TimeInterval,
        continuationBaselineText: String? = nil
    ) async -> LingShuCLIResult {
        let deadline = Date().addingTimeInterval(max(1, timeout))
        var lastText = ""
        var resolvedRecordID = recordID

        while Date() < deadline {
            do {
                let chat = try await callTool("lingshu_get_chat", arguments: ["limit": 200])
                let messages = (chat["messages"] as? [[String: Any]]) ?? []
                let candidate = Self.selectAssistantMessage(
                    from: messages,
                    assistantMessageID: assistantMessageID,
                    recordID: resolvedRecordID,
                    preferLatestRecordMessage: continuationBaselineText != nil
                )
                if let candidate {
                    let messageID = Self.string(candidate["id"])
                    let messageRecordID = Self.string(candidate["taskRecordID"])
                    if resolvedRecordID.isEmpty { resolvedRecordID = messageRecordID }
                    let text = Self.string(candidate["text"])
                    if !text.isEmpty { lastText = text }
                    if let interaction = Self.parseInteraction(candidate["humanInteraction"]) {
                        return .init(
                            status: .needsUserAction,
                            reply: text,
                            recordID: resolvedRecordID,
                            messageID: messageID,
                            interaction: interaction
                        )
                    }

                    let loading = (candidate["isLoading"] as? Bool) ?? false
                    if resolvedRecordID.isEmpty,
                       !loading,
                       !text.isEmpty,
                       continuationBaselineText == nil || text != continuationBaselineText {
                        return .init(status: .completed, reply: text, messageID: messageID)
                    }
                    if !resolvedRecordID.isEmpty,
                       let detail = try? await callTool("lingshu_task_detail", arguments: ["recordId": resolvedRecordID]) {
                        let status = Self.string(detail["status"])
                        let summary = Self.string(detail["summary"])
                        let finalText = text.isEmpty ? summary : text
                        if status == "待用户", continuationBaselineText == nil {
                            let interaction = LingShuCLIHumanInteraction(
                                id: "record:\(resolvedRecordID)",
                                kind: "question",
                                title: "User action required",
                                prompt: finalText,
                                options: [],
                                materials: []
                            )
                            return .init(
                                status: .needsUserAction,
                                reply: finalText,
                                recordID: resolvedRecordID,
                                messageID: messageID,
                                interaction: interaction
                            )
                        }
                        if (detail["isTerminal"] as? Bool) == true {
                            let successful = (detail["isSuccessful"] as? Bool) == true
                            return .init(
                                status: successful ? .completed : .failed,
                                reply: finalText,
                                recordID: resolvedRecordID,
                                messageID: messageID
                            )
                        }
                        if ["异常", "已暂停"].contains(status), !loading {
                            return .init(
                                status: .failed,
                                reply: finalText,
                                recordID: resolvedRecordID,
                                messageID: messageID
                            )
                        }
                    }
                }
            } catch {
                // A transient poll failure must not duplicate the user's prompt. Keep the
                // accepted turn alive and retry the read-only query until the deadline.
            }
            try? await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
        }
        return .init(
            status: .timedOut,
            reply: lastText.isEmpty ? "The task is still running in LingShu." : lastText,
            recordID: resolvedRecordID,
            messageID: assistantMessageID
        )
    }

    private func healthCheck() async -> Bool {
        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/health"
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        guard JSONSerialization.isValidJSONObject(body) else {
            throw LingShuCLIError.invalidResponse("The request could not be encoded.")
        }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-LingShu-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LingShuCLIError.remote("LingShu control service rejected the request.")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LingShuCLIError.invalidResponse("The JSON-RPC envelope is malformed.")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw LingShuCLIError.remote(Self.string(error["message"]))
        }
        guard let result = envelope["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw LingShuCLIError.invalidResponse("The tool result has no text content.")
        }
        if (result["isError"] as? Bool) == true {
            throw LingShuCLIError.remote(text)
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return object
        }
        return ["text": text]
    }

    static func selectAssistantMessage(
        from messages: [[String: Any]],
        assistantMessageID: String,
        recordID: String,
        preferLatestRecordMessage: Bool = false
    ) -> [String: Any]? {
        if preferLatestRecordMessage,
           !recordID.isEmpty,
           let byRecord = messages.last(where: {
               (($0["isUser"] as? Bool) != true) && string($0["taskRecordID"]) == recordID
           }) {
            return byRecord
        }
        if !assistantMessageID.isEmpty,
           let exact = messages.last(where: { string($0["id"]) == assistantMessageID }) {
            return exact
        }
        if !recordID.isEmpty,
           let byRecord = messages.last(where: {
               (($0["isUser"] as? Bool) != true) && string($0["taskRecordID"]) == recordID
           }) {
            return byRecord
        }
        return messages.last(where: { ($0["isUser"] as? Bool) != true })
    }

    private static func parseInteraction(_ raw: Any?) -> LingShuCLIHumanInteraction? {
        guard let object = raw as? [String: Any] else { return nil }
        let options = ((object["options"] as? [[String: Any]]) ?? []).map {
            LingShuCLIOption(
                id: string($0["id"]),
                label: string($0["label"]),
                detail: string($0["detail"]),
                value: string($0["value"])
            )
        }
        let materials = ((object["materials"] as? [[String: Any]]) ?? []).map {
            LingShuCLIMaterial(
                id: string($0["id"]),
                kind: string($0["kind"]),
                title: string($0["title"]),
                value: string($0["value"]),
                mimeType: string($0["mimeType"]).nilIfEmpty
            )
        }
        return .init(
            id: string(object["id"]),
            kind: string(object["kind"]),
            title: string(object["title"]),
            prompt: string(object["prompt"]),
            options: options,
            materials: materials
        )
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
