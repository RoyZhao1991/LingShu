import Foundation

@MainActor
extension LingShuState {
    /// 启动时验证的是“当前配置能否真的得到模型回复”，而不只是检查字段是否非空。
    /// 首次安装没有凭据时直接进入引导，不启动主会话预热，避免无效请求和误报。
    func prepareBrainOnLaunch() async -> Bool {
        guard brainSetupPhase == .unchecked else { return brainSetupPhase == .ready }
        brainSetupPhase = .checking

        guard let preset = selectedModelPreset else {
            brainSetupPhase = .required(reason: loc(
                "当前主脑配置无法识别，请重新选择服务。",
                "The current brain configuration is not recognized. Choose a provider again."
            ))
            return false
        }

        let keyless = preset.authMode.contains("无") || preset.authMode.contains("本地") || preset.authMode.contains("登录")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyless || !trimmedKey.isEmpty else {
            brainSetupPhase = .required(reason: loc(
                "尚未配置可用的主脑 Token。",
                "No usable brain token is configured."
            ))
            return false
        }

        let configuration = LingShuBrainSetupConfiguration(
            providerID: preset.id,
            providerName: modelProvider,
            endpoint: endpoint,
            model: modelName,
            protocolName: preset.protocolName,
            apiKey: keyless && trimmedKey.isEmpty ? "local-keyless" : trimmedKey
        )
        if let error = configuration.inputError {
            brainSetupPhase = .required(reason: error.localizedDescription)
            return false
        }

        let result = await probeBrainConfiguration(configuration, permitsKeyless: keyless)
        channelValidations[Self.brainChannelKey(modelProvider)] = result
        if result.ok {
            brainSetupPhase = .ready
            return true
        }
        brainSetupPhase = .required(reason: loc("当前主脑不可用：", "The current brain is unavailable: ") + result.detail)
        return false
    }

    /// 候选配置先做真实请求；只有成功后才进入正式配置，避免错误 Token 污染当前通道。
    func installBrainFromSetup(_ configuration: LingShuBrainSetupConfiguration) async -> LingShuChannelValidation {
        let result = await probeBrainConfiguration(configuration)
        guard result.ok else {
            brainSetupPhase = .required(reason: result.detail)
            return result
        }

        let trimmedKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credentialStore.setAPIKey(trimmedKey, forProvider: configuration.providerID) else {
            let detail = loc(
                "模型连接成功，但 Token 无法安全写入 macOS 钥匙串。请解锁登录钥匙串后重试。",
                "The model responded, but the token could not be saved securely in macOS Keychain. Unlock the login keychain and try again."
            )
            let storageFailure = LingShuChannelValidation(ok: false, detail: detail, at: Date())
            brainSetupPhase = .required(reason: detail)
            return storageFailure
        }

        modelProvider = configuration.providerName
        endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmedKey
        rememberBrainModel(modelName, for: modelProvider)

        channelValidations[Self.brainChannelKey(modelProvider)] = result
        actualBrainProvider = modelProvider
        actualBrainModel = modelName
        actualBrainAt = Date()
        resetBrainScoreForCurrentBrain()
        mainAgentSessionHolder = nil
        autonomousSessionHolder = nil
        brainSetupPhase = .ready

        logEvent("现在  主脑已连接：\(modelProvider) / \(modelName)。")
        appendTrace(
            kind: .system,
            actor: "配置",
            title: "主脑接入完成",
            detail: "\(modelProvider) / \(modelName) 已通过真实响应校验。"
        )
        publishControlSnapshot()

        Task { @MainActor [weak self] in
            _ = await self?.mainAgentSession()
        }
        return result
    }

    func probeBrainConfiguration(
        _ configuration: LingShuBrainSetupConfiguration,
        permitsKeyless: Bool = false
    ) async -> LingShuChannelValidation {
        if !permitsKeyless, let error = configuration.inputError {
            return .init(ok: false, detail: error.localizedDescription, at: Date())
        }

        let adapter = LingShuGatewayAgentModel(
            client: remoteModelClient,
            provider: configuration.providerName,
            model: configuration.model,
            endpoint: configuration.endpoint,
            protocolName: configuration.protocolName,
            apiKey: permitsKeyless && configuration.apiKey == "local-keyless" ? "" : configuration.apiKey,
            temperature: 0,
            timeout: 20
        )
        let session = LingShuAgentSession(
            id: "brain-setup-\(UUID().uuidString.prefix(6))",
            tools: [],
            model: adapter,
            maxTurns: 1
        )
        let result = await session.send("连接校验：请只回复两个字‘在的’。")
        switch result {
        case .completed(let text):
            let clean = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                ok: !clean.isEmpty,
                detail: clean.isEmpty ? loc("模型没有返回正文", "The model returned no response body") : loc("连接成功，模型已响应", "Connected; the model responded"),
                at: Date()
            )
        case .interrupted(let reason):
            return .init(ok: false, detail: String(reason.prefix(160)), at: Date())
        case .blocked:
            return .init(ok: false, detail: loc("连接校验被意外阻塞", "Connection verification was unexpectedly blocked"), at: Date())
        case .maxTurnsReached(let lastText):
            let clean = LingShuReasoningText.stripThinkTags(lastText).trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                ok: !clean.isEmpty,
                detail: clean.isEmpty ? loc("连接校验未得到回复", "Connection verification received no reply") : loc("连接成功，模型已响应", "Connected; the model responded"),
                at: Date()
            )
        }
    }
}
