import Foundation

struct LingShuGrokRuntimeEvent: Sendable {
    var actor: String
    var role: String
    var kind: LingShuTaskExecutionMessageKind
    var text: String
    var detail: LingShuTaskExecutionDetail?
}

struct LingShuGrokNewSessionParams: Codable, Sendable {
    struct AgentProfile: Codable, Sendable {
        var name: String
        var description: String
        var tools: [String]
        var injectDefaultTools: Bool
        var discoverSkills: Bool
        var agentsMd: Bool
        var maxTurns: Int

        static let checker = AgentProfile(
            name: "lingshu-checker",
            description: "Independent LingShu delivery checker",
            tools: ["Read", "Glob", "Grep", "Bash"],
            injectDefaultTools: true,
            discoverSkills: false,
            agentsMd: false,
            maxTurns: 30
        )
    }

    struct Meta: Codable, Sendable {
        var modelId: String
        var rules: String
        var agentProfile: AgentProfile? = nil
        var yoloMode = false
        var autoMode = false
        var clientIdentifier = "lingshu"
    }

    var cwd: String
    var mcpServers: [String] = []
    var meta: Meta

    enum CodingKeys: String, CodingKey {
        case cwd, mcpServers
        case meta = "_meta"
    }
}

func lingShuGrokNewSessionParams(
    workingDirectory: String,
    modelID: String,
    systemPrompt: String,
    role: LingShuEmbeddedAgentRole,
    permissionMode: LingShuExecutionPermissionMode
) -> LingShuGrokNewSessionParams {
    let permissionRule = permissionMode == .fullAccess
        ? "Execution permission is full_access. Local commands, network access, dependency installation, and paths outside the working directory are already authorized. Do not ask again solely for those operations. Login, credentials, payment, physical actions, and OS privacy grants still require the user."
        : "Execution permission is sandbox. Network access and writes outside the working directory require explicit user authorization; request the exact permission instead of claiming the platform permanently lacks the capability."
    return LingShuGrokNewSessionParams(
        cwd: workingDirectory,
        meta: .init(
            modelId: modelID,
            rules: systemPrompt + "\n\n" + permissionRule,
            agentProfile: role == .checker ? .checker : nil,
            yoloMode: permissionMode == .fullAccess
        )
    )
}

private struct LingShuGrokPromptParams: Codable, Sendable {
    struct ContentBlock: Codable, Sendable {
        var type: String
        var text: String?
        var data: String?
        var mimeType: String?

        static func text(_ value: String) -> Self {
            .init(type: "text", text: value, data: nil, mimeType: nil)
        }

        static func image(data: String, mimeType: String) -> Self {
            .init(type: "image", text: nil, data: data, mimeType: mimeType)
        }
    }
    var sessionId: String
    var prompt: [ContentBlock]
}

private struct LingShuGrokInterjectParams: Codable, Sendable {
    var sessionId: String
    var text: String
    var interjectionId: String
}

/// 把进程内 Grok runtime 的一条 ACP 逻辑会话包装成灵枢默认 Agent 槽。
/// Maker 与 Checker 使用同一常驻 Runtime、不同 session；显式外部 Agent 不走这里。
actor LingShuGrokAgentSession: LingShuAgentSessioning {
    let id: String
    let role: LingShuEmbeddedAgentRole
    let workingDirectory: String
    let modelID: String
    let permissionMode: LingShuExecutionPermissionMode

    private let systemPrompt: String
    private let client: LingShuEmbeddedGrokClient
    private let eventSink: @Sendable (LingShuGrokRuntimeEvent) async -> Void

    private(set) var turnsUsed = 0
    private(set) var toolInvocations: [String] = []
    private(set) var messages: [LingShuAgentMessage] = []
    private(set) var isBlocked = false

    private var runtimeSessionID: String?
    private var eventReader: Task<Void, Never>?
    private var promptInFlight = false
    private var promptResult: Result<Data, Error>?
    private var pendingInteraction: Data?
    private var pendingInteractionMethod: String?
    private var pendingCorrection: String?
    private var pendingBriefings: [String] = []
    private var textDeltaSink: (@Sendable (String) async -> Void)?
    private var finalText = ""
    private var thoughtBuffer = ""

    init(
        id: String,
        role: LingShuEmbeddedAgentRole,
        workingDirectory: String,
        modelID: String,
        permissionMode: LingShuExecutionPermissionMode,
        systemPrompt: String,
        initialMessages: [LingShuAgentMessage],
        client: LingShuEmbeddedGrokClient,
        eventSink: @escaping @Sendable (LingShuGrokRuntimeEvent) async -> Void
    ) {
        self.id = id
        self.role = role
        self.workingDirectory = workingDirectory
        self.modelID = modelID
        self.permissionMode = permissionMode
        let bootstrap = initialMessages.map { message in
            "【\(message.role.rawValue)上下文】\n\(message.content)"
        }.joined(separator: "\n\n")
        self.systemPrompt = bootstrap.isEmpty ? systemPrompt : systemPrompt + "\n\n" + bootstrap
        self.client = client
        self.eventSink = eventSink
        messages = [.init(role: .system, content: systemPrompt)] + initialMessages
    }

    deinit { eventReader?.cancel() }

    func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {
        textDeltaSink = sink
    }

    func send(_ userText: String) async -> LingShuAgentRunResult {
        await send(userText, imageDataURLs: nil)
    }

    func send(_ userText: String, imageDataURLs: [String]?) async -> LingShuAgentRunResult {
        guard !promptInFlight else { return await awaitCurrentPrompt() }
        do {
            try await ensureRuntimeSession()
            let prompt = makePrompt(userText, imageDataURLs: imageDataURLs)
            let promptBlocks = makePromptBlocks(text: prompt, dataURLs: imageDataURLs)
            messages.append(.init(role: .user, content: userText, imageDataURLs: imageDataURLs))
            turnsUsed += 1
            finalText = ""
            thoughtBuffer = ""
            promptResult = nil
            promptInFlight = true
            let client = self.client
            Task {
                let result: Result<Data, Error>
                do {
                    result = .success(try await client.request(
                        "session/prompt",
                        params: LingShuGrokPromptParams(
                            sessionId: self.runtimeSessionID ?? "",
                            prompt: promptBlocks
                        )
                    ))
                } catch {
                    result = .failure(error)
                }
                self.finishPromptRequest(result)
            }
            return await awaitCurrentPrompt()
        } catch {
            return .interrupted(reason: error.localizedDescription)
        }
    }

    func resume(_ answer: String) async -> LingShuAgentRunResult {
        if let request = pendingInteraction {
            do {
                if pendingInteractionMethod == "session/request_permission" {
                    let denied = answer.localizedCaseInsensitiveContains("拒绝")
                        || answer.localizedCaseInsensitiveContains("deny")
                    try await client.respondToPermission(request: request, allow: !denied)
                } else if pendingInteractionMethod?.hasSuffix("exit_plan_mode") == true {
                    try await client.respondToPlanApproval(request: request, answer: answer)
                } else {
                    try await client.respondToQuestion(request: request, answer: answer)
                }
                messages.append(.init(role: .user, content: answer))
                pendingInteraction = nil
                pendingInteractionMethod = nil
                isBlocked = false
                return await awaitCurrentPrompt()
            } catch {
                return .interrupted(reason: error.localizedDescription)
            }
        }
        return await send(answer)
    }

    func continueLoop() async -> LingShuAgentRunResult {
        if promptInFlight { return await awaitCurrentPrompt() }
        return await send("继续完成当前任务；核对真实产出、构建和测试后再收尾。")
    }

    @discardableResult
    func injectCorrection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard promptInFlight, let runtimeSessionID else {
            pendingCorrection = trimmed
            return false
        }
        messages.append(.init(role: .user, content: "【中途纠正】\(trimmed)"))
        let client = self.client
        Task {
            do {
                _ = try await client.request(
                    "_x.ai/interject",
                    params: LingShuGrokInterjectParams(
                        sessionId: runtimeSessionID,
                        text: trimmed,
                        interjectionId: UUID().uuidString
                    )
                )
                await emit(actor: "灵枢", role: "中途纠正", kind: .user, text: trimmed)
            } catch {
                pendingCorrection = trimmed
                await emit(actor: "灵枢 Runtime", role: "纠正未送达", kind: .warning, text: error.localizedDescription)
            }
        }
        return true
    }

    func injectBriefing(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pendingBriefings.append(trimmed) }
    }

    private func ensureRuntimeSession() async throws {
        guard runtimeSessionID == nil else { return }
        let params = lingShuGrokNewSessionParams(
            workingDirectory: workingDirectory,
            modelID: modelID,
            systemPrompt: systemPrompt,
            role: role,
            permissionMode: permissionMode
        )
        let response = try await client.request("session/new", params: params)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let sessionID = result["sessionId"] as? String,
              !sessionID.isEmpty else {
            throw LingShuEmbeddedGrokRuntimeError.invalidRuntimeMessage
        }
        runtimeSessionID = sessionID
        startEventReader(sessionID: sessionID)
        await emit(actor: "灵枢 Runtime", role: "\(role.roleName) 引擎", kind: .agent, text: "已创建常驻 Runtime 独立 \(role.roleName) 会话 \(sessionID)")
    }

    private func startEventReader(sessionID: String) {
        let client = self.client
        eventReader = Task { [weak self] in
            while !Task.isCancelled {
                guard let event = await client.nextEvent(sessionID: sessionID) else { break }
                guard !Task.isCancelled else { break }
                await self?.consumeEvent(event)
            }
        }
    }

    private func finishPromptRequest(_ result: Result<Data, Error>) {
        promptResult = result
    }

    private func awaitCurrentPrompt() async -> LingShuAgentRunResult {
        while promptInFlight {
            if Task.isCancelled {
                if let runtimeSessionID { try? await client.cancelSession(sessionID: runtimeSessionID) }
                promptInFlight = false
                return .interrupted(reason: "任务已取消")
            }
            if let request = pendingInteraction {
                isBlocked = true
                return .blocked(question: interactionQuestion(from: request))
            }
            if let result = promptResult {
                promptResult = nil
                promptInFlight = false
                flushThoughtBuffer()
                switch result {
                case .failure(let error):
                    return .interrupted(reason: error.localizedDescription)
                case .success:
                    let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let completion = text.isEmpty ? "Runtime 已完成本轮，但没有返回文本摘要。" : text
                    messages.append(.init(role: .assistant, content: completion))
                    await emit(actor: "灵枢 Runtime", role: "\(role.roleName) 完成", kind: .result, text: completion)
                    return .completed(text: completion)
                }
            }
            do {
                try await Task.sleep(nanoseconds: 40_000_000)
            } catch {
                continue
            }
        }
        return .interrupted(reason: "Runtime 会话没有正在执行的回合")
    }

    private func makePrompt(_ userText: String, imageDataURLs: [String]?) -> String {
        var sections: [String] = []
        if !pendingBriefings.isEmpty {
            sections.append("【灵枢主线程简报】\n" + pendingBriefings.map { "- \($0)" }.joined(separator: "\n"))
            pendingBriefings.removeAll()
        }
        if let correction = pendingCorrection {
            sections.append("【用户中途纠正，最高优先级】\n\(correction)")
            pendingCorrection = nil
        }
        sections.append(userText)
        return sections.joined(separator: "\n\n")
    }

    private func makePromptBlocks(text: String, dataURLs: [String]?) -> [LingShuGrokPromptParams.ContentBlock] {
        var blocks: [LingShuGrokPromptParams.ContentBlock] = [.text(text)]
        var unsupported = 0
        for url in dataURLs ?? [] {
            guard url.hasPrefix("data:"),
                  let marker = url.range(of: ";base64,"),
                  marker.lowerBound > url.startIndex else {
                unsupported += 1
                continue
            }
            let mimeStart = url.index(url.startIndex, offsetBy: 5)
            let mime = String(url[mimeStart..<marker.lowerBound])
            let data = String(url[marker.upperBound...])
            if mime.hasPrefix("image/"), !data.isEmpty {
                blocks.append(.image(data: data, mimeType: mime))
            } else {
                unsupported += 1
            }
        }
        if unsupported > 0 {
            blocks.append(.text("【附件提示】有 \(unsupported) 个非图片附件无法内联到当前 Runtime 会话；如任务依赖它们，请使用工作目录中的原始文件。"))
        }
        return blocks
    }

    private func consumeEvent(_ data: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else { return }

        if method == "session/request_permission" || method.hasSuffix("ask_user_question") || method.hasSuffix("exit_plan_mode") {
            pendingInteraction = data
            pendingInteractionMethod = method
            await emit(
                actor: "灵枢 Runtime",
                role: "等待输入",
                kind: .warning,
                text: interactionQuestion(from: data)
            )
            return
        }

        guard method == "session/update"
                || method.hasSuffix("session/update")
                || method.hasSuffix("session_notification"),
              let params = object["params"] as? [String: Any] else { return }
        let update = (params["update"] as? [String: Any]) ?? params
        let updateType = (update["sessionUpdate"] as? String) ?? (update["type"] as? String) ?? "runtime_update"

        switch updateType {
        case "agent_message_chunk":
            let text = Self.contentText(update)
            finalText += text
            if let textDeltaSink, !text.isEmpty { await textDeltaSink(text) }
        case "agent_thought_chunk", "thought_chunk":
            thoughtBuffer += Self.contentText(update)
            if thoughtBuffer.contains("\n") || thoughtBuffer.count >= 180 { flushThoughtBuffer() }
        case "tool_call", "tool_call_update":
            let tool = Self.firstString(in: update, keys: ["title", "name", "toolName", "kind"]) ?? "Runtime Tool"
            if updateType == "tool_call" { toolInvocations.append(tool) }
            let arguments = Self.jsonString(update["rawInput"] ?? update["input"] ?? update["content"])
            let status = Self.firstString(in: update, keys: ["status", "summary"]) ?? (updateType == "tool_call" ? "开始执行" : "状态更新")
            let detail: LingShuTaskExecutionDetail = updateType == "tool_call"
                ? .toolCall(tool: tool, summary: status, arguments: arguments)
                : .toolResult(tool: tool, success: status != "failed", output: arguments)
            await emit(actor: role.actorName, role: "工具", kind: .agent, text: "\(tool)：\(status)", detail: detail)
        case "plan":
            let entries = update["entries"] as? [[String: Any]] ?? []
            let lines = entries.compactMap { entry -> String? in
                guard let content = Self.firstString(in: entry, keys: ["content", "title", "description"]) else { return nil }
                let status = Self.firstString(in: entry, keys: ["status"]) ?? "pending"
                return "[\(status)] \(content)"
            }
            await emit(
                actor: role.actorName,
                role: "执行计划",
                kind: .review,
                text: lines.isEmpty ? "Runtime 已更新执行计划" : lines.joined(separator: "\n")
            )
        case "turn_completed":
            if finalText.isEmpty, let result = update["agentResult"] as? String { finalText = result }
            let reason = Self.firstString(in: update, keys: ["stopReason", "status"]) ?? "end_turn"
            await emit(actor: role.actorName, role: "回合", kind: .model, text: "Runtime 回合结束：\(reason)")
        case "retry_state", "auto_recovery_started", "auto_recovery_exhausted", "auto_compact_failed":
            await emit(actor: "灵枢 Runtime", role: "恢复 / 重试", kind: .warning, text: Self.summary(update, fallback: updateType))
        case "hook_annotation":
            await emit(actor: role.actorName, role: "Hook", kind: .agent, text: Self.summary(update, fallback: updateType))
        default:
            if updateType.contains("subagent") {
                await emit(actor: "灵枢子 Agent", role: "内部编排", kind: .agent, text: Self.summary(update, fallback: updateType))
            } else if updateType.contains("goal") || updateType.contains("plan") || updateType.contains("verif") || updateType == "turn_completed" {
                await emit(actor: role.actorName, role: "规划 / 自检", kind: .review, text: Self.summary(update, fallback: updateType))
            }
        }
    }

    private func flushThoughtBuffer() {
        let text = thoughtBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        thoughtBuffer = ""
        guard !text.isEmpty else { return }
        let sink = eventSink
        let actor = role.actorName
        Task { await sink(.init(actor: actor, role: "思考", kind: .model, text: text, detail: nil)) }
    }

    private func interactionQuestion(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else {
            return "Runtime 等待你的输入"
        }
        if method == "session/request_permission" {
            let title = (params["toolCall"] as? [String: Any])?["title"] as? String
                ?? (params["toolCall"] as? [String: Any])?["name"] as? String
                ?? "工具操作"
            return "Runtime 请求授权：\(title)。回复“允许”或“拒绝”。"
        }
        if let questions = params["questions"] as? [[String: Any]],
           let question = questions.first?["question"] as? String {
            return question
        }
        return method.hasSuffix("exit_plan_mode") ? "Runtime 已完成计划，是否继续实施？" : "Runtime 等待你的输入"
    }

    private func emit(
        actor: String,
        role: String,
        kind: LingShuTaskExecutionMessageKind,
        text: String,
        detail: LingShuTaskExecutionDetail? = nil
    ) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        await eventSink(.init(actor: actor, role: role, kind: kind, text: clean, detail: detail))
    }

    private static func contentText(_ object: [String: Any]) -> String {
        if let content = object["content"] as? [String: Any], let text = content["text"] as? String { return text }
        return object["text"] as? String ?? ""
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys where object[key] is String { return object[key] as? String }
        return nil
    }

    private static func summary(_ object: [String: Any], fallback: String) -> String {
        firstString(in: object, keys: ["message", "summary", "title", "status", "goal", "description"]) ?? fallback
    }

    private static func jsonString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return string
    }
}
