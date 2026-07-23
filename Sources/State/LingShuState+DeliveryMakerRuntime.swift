import Foundation

@MainActor
extension LingShuState {
    /// 灵枢启动阶段预热内置原生 Loop。Runtime 与 App 同寿命，默认 Maker / Checker
    /// 分别创建独立逻辑 session；显式外部 Agent 仍走原有插件调用链。
    func prepareLoopRuntimeOnLaunch() async {
        await reconcileLoopRuntime()
    }

    func setLoopEngine(_ engine: LingShuLoopEngine) {
        loopEngine = engine
    }

    func scheduleLoopRuntimeRefresh() {
        loopRuntimeRefreshTask?.cancel()
        loopRuntimeRefreshTask = Task { @MainActor [weak self] in
            // 合并设置页连续修改 provider / endpoint / model / token 产生的短促变更。
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.reconcileLoopRuntime()
        }
    }

    private func reconcileLoopRuntime() async {
        let runtime = LingShuEmbeddedGrokRuntime.shared
        // 正在执行或仍可返工的逻辑会话必须保住上下文；模型通道变更不热杀 Runtime。
        // 下次 App 启动时才用新配置重建。
        if runtime.status.isReady || runtime.status == .starting {
            return
        }

        do {
            let configuration = try makeEmbeddedLoopConfiguration()
            await runtime.start(configuration: configuration)
        } catch {
            runtime.reportConfigurationFailure(error.localizedDescription)
        }
    }

    func makeEmbeddedLoopSession(
        id: String,
        role: LingShuEmbeddedAgentRole,
        workingDirectory: String,
        systemPrompt: String,
        initialMessages: [LingShuAgentMessage] = [],
        recordID: String?
    ) -> LingShuGrokAgentSession? {
        return LingShuEmbeddedGrokRuntime.shared.makeSession(
            id: id,
            role: role,
            workingDirectory: workingDirectory,
            modelID: "lingshu-active",
            permissionMode: executionPermissionMode,
            systemPrompt: systemPrompt,
            initialMessages: initialMessages,
            eventSink: { [weak self] event in
                await MainActor.run {
                    self?.appendTaskRecordMessage(
                        recordID,
                        actor: event.actor,
                        role: event.role,
                        kind: event.kind,
                        text: event.text,
                        detail: event.detail
                    )
                }
            }
        )
    }

    private func makeEmbeddedLoopConfiguration() throws -> LingShuEmbeddedGrokStartConfiguration {
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let format = LingShuModelGateway().requestFormat(
            provider: modelProvider,
            endpoint: endpoint,
            protocolName: protocolName
        )
        guard format != .hostAdapter else {
            throw LingShuLoopConfigurationError.unsupportedHostAdapter(protocolName)
        }

        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = Self.runtimeBaseURL(endpoint, format: format)
        guard !trimmedModel.isEmpty else { throw LingShuLoopConfigurationError.missingModel }
        guard !trimmedEndpoint.isEmpty else { throw LingShuLoopConfigurationError.missingEndpoint }

        let backend: String
        switch format {
        case .chatCompletions: backend = "chat_completions"
        case .responses: backend = "responses"
        case .anthropicMessages: backend = "messages"
        case .hostAdapter: backend = "chat_completions"
        }
        let authScheme = format == .anthropicMessages ? "x_api_key" : "bearer"
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialLine = token.isEmpty ? "" : "\napi_key = \"\(Self.tomlEscaped(token))\""
        let extraHeaders = format == .anthropicMessages
            ? "\nextra_headers = { \"anthropic-version\" = \"2023-06-01\" }"
            : ""

        let toml = """
        [cli]
        auto_update = false

        [features]
        telemetry = false
        feedback = false

        [models]
        default = "lingshu-active"
        web_search = "lingshu-active"
        session_summary = "lingshu-active"
        image_description = "lingshu-active"
        prompt_suggestion = "lingshu-active"

        [model.lingshu-active]
        id = "lingshu-active"
        name = "LingShu Active Model"
        model = "\(Self.tomlEscaped(trimmedModel))"
        base_url = "\(Self.tomlEscaped(trimmedEndpoint))"
        api_backend = "\(backend)"
        auth_scheme = "\(authScheme)"
        context_window = 200000
        supported_in_api = true\(credentialLine)\(extraHeaders)
        """

        let home = LingShuRuntimeEnvironment.applicationSupportDirectory(using: .default)
            .appendingPathComponent("LingShu/GrokRuntime", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .init(
            grokHome: home.path,
            configToml: toml,
            environment: [
                "LINGSHU_EXECUTION_PERMISSION_MODE": executionPermissionMode == .fullAccess
                    ? "full_access"
                    : "sandbox",
                "LINGSHU_NETWORK_ACCESS": executionPermissionMode == .fullAccess
                    ? "allowed"
                    : "restricted",
                "LINGSHU_WORKSPACE": agentWorkingDirectory,
            ]
        )
    }

    private static func runtimeBaseURL(_ raw: String, format: LingShuModelGatewayRequestFormat) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes: [String]
        switch format {
        case .chatCompletions: suffixes = ["/chat/completions"]
        case .responses: suffixes = ["/responses"]
        case .anthropicMessages: suffixes = ["/messages"]
        case .hostAdapter: suffixes = []
        }
        for suffix in suffixes where value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func tomlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

private enum LingShuLoopConfigurationError: LocalizedError {
    case missingModel
    case missingEndpoint
    case unsupportedHostAdapter(String)

    var errorDescription: String? {
        switch self {
        case .missingModel: return "当前模型名称为空"
        case .missingEndpoint: return "当前模型端点为空"
        case .unsupportedHostAdapter(let name): return "内嵌 Runtime 暂不支持主机适配协议：\(name)"
        }
    }
}
