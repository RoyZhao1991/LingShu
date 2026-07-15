import Foundation

@MainActor
extension LingShuState {
    /// 启动时验证的是“当前配置能否真的得到模型回复”，而不只是检查字段是否非空。
    /// 首次安装没有凭据时直接进入引导，不启动主会话预热，避免无效请求和误报。
    func prepareBrainOnLaunch() async -> Bool {
        guard brainSetupPhase == .unchecked else { return brainSetupPhase == .ready }
        brainSetupPhase = .checking

        guard let preset = selectedModelPreset else {
            brainSetupPhase = .required(reason: "当前主脑配置无法识别，请重新选择服务。")
            return false
        }

        let keyless = preset.authMode.contains("无") || preset.authMode.contains("本地") || preset.authMode.contains("登录")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyless || !trimmedKey.isEmpty else {
            brainSetupPhase = .required(reason: "尚未配置可用的主脑 Token。")
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
        brainSetupPhase = .required(reason: "当前主脑不可用：\(result.detail)")
        return false
    }

    /// 候选配置先做真实请求；只有成功后才进入正式配置，避免错误 Token 污染当前通道。
    func installBrainFromSetup(_ configuration: LingShuBrainSetupConfiguration) async -> LingShuChannelValidation {
        let result = await probeBrainConfiguration(configuration)
        guard result.ok else {
            brainSetupPhase = .required(reason: result.detail)
            return result
        }

        modelProvider = configuration.providerName
        endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        credentialStore.setAPIKey(configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forProvider: configuration.providerID)
        apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return .init(ok: !clean.isEmpty, detail: clean.isEmpty ? "模型没有返回正文" : "连接成功，模型已响应", at: Date())
        case .interrupted(let reason):
            return .init(ok: false, detail: String(reason.prefix(160)), at: Date())
        case .blocked:
            return .init(ok: false, detail: "连接校验被意外阻塞", at: Date())
        case .maxTurnsReached(let lastText):
            let clean = LingShuReasoningText.stripThinkTags(lastText).trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(ok: !clean.isEmpty, detail: clean.isEmpty ? "连接校验未得到回复" : "连接成功，模型已响应", at: Date())
        }
    }
}
