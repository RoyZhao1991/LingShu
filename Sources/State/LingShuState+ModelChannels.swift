import Foundation

/// 能力通道校验结果(实测某通道是否真能用)。
struct LingShuChannelValidation: Codable, Equatable, Sendable {
    var ok: Bool
    var detail: String
    var at: Date
}

/// 能力通道(口/眼/耳)的用户配置:自定义显示名 + 接口地址 + 模型名(密钥另存 credentialStore)。
struct ModelChannelConfig: Codable, Equatable, Sendable {
    var name: String = ""
    var endpoint: String = ""
    var model: String = ""
}

/// 模型通道 = 带校验的**类型化能力通道**注册表(中枢/视觉/视频/听/语音)。
/// 取向(用户拍板 2026-06-16):TTS/音视频通道也在模型通道里配置;眼耳口鼻嘴内部只**选已配置且校验通过**的通道;
/// 子线程切换 + 各模态选择器都**过滤掉未配置/未校验通过**的通道,不让没真接上的模型出现在可切换列表里。
@MainActor
extension LingShuState {

    // MARK: - 通道 key(纯字符串,nonisolated 便于 UI/测试共用)
    nonisolated static func brainChannelKey(_ provider: String) -> String { "brain:\(provider)" }
    nonisolated static let visionChannelKey = "vision:datanet"
    nonisolated static let visionCustomKey = "vision:custom"
    nonisolated static let videoChannelKey = "video:datanet"
    nonisolated static let asrChannelKey = "asr:datanet"
    nonisolated static let asrCustomKey = "asr:custom"
    nonisolated static func ttsChannelKey(_ id: String) -> String { "tts:\(id)" }

    // MARK: - 感知通道默认值(视觉/听觉走数据网关专项接口;配置项留空时展示这些真实默认,而不是空白)
    nonisolated static let perceptionGatewayEndpoint = "https://model-gateway.datanet.bj.cn/v1"
    nonisolated static let visionDefaultModel = "qwen2.5-vl"
    nonisolated static let asrDefaultModel = "swds-realtime-hearing"

    func channelValidation(_ key: String) -> LingShuChannelValidation? { channelValidations[key] }
    func isChannelValidated(_ key: String) -> Bool { channelValidations[key]?.ok == true }
    func isChannelValidating(_ key: String) -> Bool { validatingChannels.contains(key) }

    // MARK: - 通用通道配置(口/眼/耳:名/端点/模型 + 密钥)
    func channelConfig(_ key: String) -> ModelChannelConfig { channelConfigs[key] ?? ModelChannelConfig() }
    func hasChannelConfig(_ key: String) -> Bool { channelConfigs[key] != nil }
    /// 该通道显示名:用户自定义优先,否则回退默认名。
    func channelDisplayName(_ key: String, default def: String) -> String {
        let n = channelConfigs[key]?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (n?.isEmpty == false) ? n! : def
    }
    /// 保存通道配置(名/端点/模型 + 可选密钥)。密钥留空则不动已存的。
    func saveChannelConfig(_ key: String, name: String, endpoint: String, model: String, secret: String?) {
        channelConfigs[key] = ModelChannelConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            credentialStore.setAPIKey(secret.trimmingCharacters(in: .whitespacesAndNewlines), forProvider: key)
        }
    }

    // MARK: - 中枢/文本 通道
    /// 已配置的文本通道(有 key,或当前激活的——它就在用)。
    func configuredTextProviders() -> [ModelProviderPreset] {
        var out: [ModelProviderPreset] = []
        if let cur = ModelProviderPreset.catalog.first(where: { $0.name == modelProvider }) { out.append(cur) }
        for preset in ModelProviderPreset.apiCatalog where preset.name != modelProvider {
            if credentialStore.apiKey(forProvider: preset.id)?.isEmpty == false { out.append(preset) }
        }
        return out
    }
    /// 可切换的文本通道(子线程 picker / 模态用):已配置 且(校验通过 或 就是当前在用的)。
    func switchableTextProviders() -> [ModelProviderPreset] {
        configuredTextProviders().filter { $0.name == modelProvider || isChannelValidated(Self.brainChannelKey($0.name)) }
    }

    /// 某文本通道的前缀缓存策略(供 UI 展示「切到它会怎么启用缓存」——OpenAI 系自动 / Anthropic 显式)。
    /// 策略由 requestFormat(按 provider/protocol/endpoint 推导)决定,所以换模型自动选对,无需各处改代码。
    func prefixCacheStrategy(for preset: ModelProviderPreset) -> LingShuPrefixCacheStrategy {
        let ep = (preset.name == modelProvider) ? endpoint : preset.endpoint
        let format = LingShuModelGateway().requestFormat(provider: preset.name, endpoint: ep, protocolName: preset.protocolName)
        return LingShuPrefixCache.strategy(for: format)
    }

    // MARK: - 语音合成 TTS 通道(口)
    /// 口的**云端 TTS 目录**(本机系统语音是兜底,不在此列):数据网关情绪语音 / IndexTTS2 / CosyVoice3 / 豆包 / 自定义。
    var ttsCloudCatalog: [LingShuSpeechOutputProviderDescriptor] {
        [.dataNetSpeakerTTS, .indexTTS2Service, .cosyVoice3Service, .doubaoService, .customHTTPService]
    }
    /// 已接入的 TTS 通道:已配置过的 + 当前在用的(默认数据网关情绪语音永远在列)。「新增」从云端目录里挑没接入的。
    func configuredTTSDescriptors() -> [LingShuSpeechOutputProviderDescriptor] {
        ttsCloudCatalog.filter { d in
            d.kind == .dataNetSpeakerTTS
                || hasChannelConfig(Self.ttsChannelKey(d.id))
                || voiceManager?.speechOutputProvider.id == d.id
        }
    }
    /// 云端目录里**还没接入**的 TTS(供「新增」挑选)。
    func unconfiguredTTSDescriptors() -> [LingShuSpeechOutputProviderDescriptor] {
        let configured = Set(configuredTTSDescriptors().map(\.id))
        return ttsCloudCatalog.filter { !configured.contains($0.id) }
    }
    func ttsDisplayName(_ descriptor: LingShuSpeechOutputProviderDescriptor) -> String {
        channelDisplayName(
            Self.ttsChannelKey(descriptor.id),
            default: descriptor.localizedDisplayName(language: language)
        )
    }

    // MARK: - 中枢模型快速切换(多模型下拉框,2026-06-29 用户要)

    /// 当前供应商在 UI 下拉框里可选的模型清单:**当前模型**(置顶)+ 该供应商**用过的模型**(持久记忆)+ 预设 defaultModels,去重保序。
    /// 这样既能在预设多模型间一键切,手填的自定义模型(如 claude-sonnet-4-6)切走后也不会从下拉里消失。
    func brainModelOptions(for preset: ModelProviderPreset) -> [String] {
        var ordered: [String] = []
        func add(_ m: String) {
            let s = m.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, !ordered.contains(s) { ordered.append(s) }
        }
        if preset.name == modelProvider { add(modelName) }   // 当前模型置顶
        recentBrainModels(for: preset.name).forEach(add)      // 该供应商用过的(含手填自定义)
        preset.defaultModels.forEach(add)                     // 预设兜底
        return ordered
    }

    /// 在**当前已激活**的供应商内切换模型(下拉框选择):只换模型名、端点/密钥不动;记住新旧模型(供下拉持续可选),
    /// 并像 applyModelProvider 一样重建常驻会话(换脑即时生效 + 记忆延续)、归零大脑评分。modelName 的 didSet 已负责持久化。
    func selectActiveBrainModel(_ model: String) {
        let m = model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, m != modelName else { return }
        rememberBrainModel(modelName, for: modelProvider)   // 记住切走前的模型,别让它从下拉消失
        modelName = m
        rememberBrainModel(m, for: modelProvider)
        resetBrainScoreForCurrentBrain()                    // 评分只属于某一颗脑
        mainAgentSessionHolder = nil
        autonomousSessionHolder = nil
        logEvent("当前供应商「\(modelProvider)」内切换模型为 \(m)。")
        appendTrace(kind: .system, actor: "配置", title: "切换模型", detail: "当前脑模型切换为 \(m)(端点/密钥不变,会话已重建、记忆延续)。")
    }

    /// 某供应商用过的模型(持久,最近用的在前)。
    func recentBrainModels(for provider: String) -> [String] {
        recentBrainModelStore()[provider] ?? []
    }

    /// 记住一个供应商用过的模型(去重、最近置前、限长 8),持久化。下拉切换 / 修改弹窗保存时都调用。
    func rememberBrainModel(_ model: String, for provider: String) {
        let m = model.trimmingCharacters(in: .whitespaces)
        let p = provider.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, !p.isEmpty else { return }
        var store = recentBrainModelStore()
        var list = store[p] ?? []
        list.removeAll { $0 == m }
        list.insert(m, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        store[p] = list
        if let data = try? JSONSerialization.data(withJSONObject: store) {
            LingShuRuntimeEnvironment.preferences.set(data, forKey: "lingshu.model.recentByProvider")
        }
    }

    private func recentBrainModelStore() -> [String: [String]] {
        guard let data = LingShuRuntimeEnvironment.preferences.data(forKey: "lingshu.model.recentByProvider"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
        return obj
    }

    // MARK: - 校验(实测调用)
    /// 中枢/文本:发一句 ping,拿到回复=通过(错 key / 连不上会被 .interrupted 捕获)。
    func validateBrainChannel(_ providerName: String) async {
        let key = Self.brainChannelKey(providerName)
        guard let preset = ModelProviderPreset.catalog.first(where: { $0.name == providerName }) else { return }
        validatingChannels.insert(key); defer { validatingChannels.remove(key) }
        let isCurrent = (providerName == modelProvider)
        let ep = isCurrent ? endpoint : preset.endpoint
        let mdl = isCurrent ? modelName : (preset.defaultModels.first ?? "")
        let k = isCurrent ? apiKey : (credentialStore.apiKey(forProvider: preset.id) ?? "")
        let keyless = preset.authMode.contains("无") || preset.authMode.contains("本地") || preset.authMode.contains("登录")
        guard !k.isEmpty || keyless else {
            channelValidations[key] = .init(ok: false, detail: "未配置密钥", at: Date()); return
        }
        let configuration = LingShuBrainSetupConfiguration(
            providerID: preset.id,
            providerName: providerName,
            endpoint: ep,
            model: mdl,
            protocolName: preset.protocolName,
            apiKey: keyless && k.isEmpty ? "local-keyless" : k
        )
        channelValidations[key] = await probeBrainConfiguration(configuration, permitsKeyless: keyless)
    }

    // MARK: - 账号余额(按需查,按厂商适配,见 LingShuChannelBalance)

    func channelBalance(_ key: String) -> LingShuChannelBalance.Result? { channelBalances[key] }
    func isChannelBalanceFetching(_ key: String) -> Bool { channelBalanceFetching.contains(key) }

    /// 查某个中枢通道(脑)的账号余额——用该 provider 存的 key 打它的余额 API,解析后落 `channelBalances`(供 UI 显示)。
    /// 不支持余额查询的厂商(Anthropic 等)直接 no-op;查失败静默(余额查不到不该打断主流程)。
    func fetchBrainChannelBalance(_ providerName: String) async {
        let key = Self.brainChannelKey(providerName)
        guard let preset = ModelProviderPreset.catalog.first(where: { $0.name == providerName }),
              let apiKey = credentialStore.apiKey(forProvider: preset.id),
              let req = LingShuChannelBalance.request(provider: providerName, apiKey: apiKey) else { return }
        channelBalanceFetching.insert(key); defer { channelBalanceFetching.remove(key) }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let r = LingShuChannelBalance.parse(provider: providerName, data: data) {
                channelBalances[key] = r
            } else {
                lingShuControlLog("balance: \(providerName) 解析不出余额(响应非预期)")
            }
        } catch {
            lingShuControlLog("balance: \(providerName) 查询失败 \(error.localizedDescription)")
        }
    }

    /// MCP `lingshu_channel_balance` 的载荷(查→解析→返回);逻辑放这边,router 只一行委托(保 router 文件瘦)。
    func controlChannelBalancePayload(provider: String) async -> [String: Any] {
        let supported = LingShuChannelBalance.isSupported(provider: provider)
        if supported { await fetchBrainChannelBalance(provider) }
        let b = channelBalance(Self.brainChannelKey(provider))
        return ["provider": provider, "supported": supported, "balance": b?.display ?? "", "available": b?.available ?? false]
    }

    /// 视觉:发一张小测试图给数据网关 VL,有语义返回=通过(视频同走数据网关,顺带标记)。
    func validateVisionChannel() async {
        let key = Self.visionChannelKey
        validatingChannels.insert(key); defer { validatingChannels.remove(key) }
        guard let vl = cloudPerceptionClient else {
            let v = LingShuChannelValidation(ok: false, detail: "云视觉未配置(缺数据网关 token)", at: Date())
            channelValidations[key] = v
            channelValidations[Self.videoChannelKey] = v
            return
        }
        let ok: Bool; let detail: String
        if let r = try? await vl.analyzeImage(imageBase64: Self.channelTestImageBase64, prompt: "这张图主要是什么颜色?一个词回答。", includeOCR: false, includeGrounding: false), r.success {
            ok = true; detail = "校验通过 · VL 返回语义"
        } else {
            ok = false; detail = "VL 调用失败/无响应"
        }
        channelValidations[key] = .init(ok: ok, detail: detail, at: Date())
        channelValidations[Self.videoChannelKey] = .init(ok: ok, detail: ok ? "数据网关可达(视频同通道)" : detail, at: Date())
    }

    /// TTS:本机语音始终可用;云端通道看数据网关 token 是否配置。
    func validateTTSChannel(_ descriptor: LingShuSpeechOutputProviderDescriptor) async {
        let key = Self.ttsChannelKey(descriptor.id)
        validatingChannels.insert(key); defer { validatingChannels.remove(key) }
        let ok: Bool; let detail: String
        switch descriptor.kind {
        case .appleSpeech, .embeddedSherpaONNXTTS:
            ok = true; detail = "本机语音 · 始终可用"
        default:
            let hasToken = (dataNetGatewayToken()?.isEmpty == false)
            ok = hasToken; detail = hasToken ? "凭据已配置 · 数据网关情绪语音" : "缺数据网关 token"
        }
        channelValidations[key] = .init(ok: ok, detail: detail, at: Date())
    }

    /// 听(语音识别):数据网关/自定义云端 ASR——看数据网关 token / 自定义端点是否配置。
    func validateASRChannel(_ key: String) {
        let custom = (key == Self.asrCustomKey)
        let ok: Bool; let detail: String
        if custom {
            ok = !channelConfig(key).endpoint.isEmpty
            detail = ok ? "自定义端点已配置" : "缺自定义端点"
        } else {
            ok = (dataNetGatewayToken()?.isEmpty == false)
            detail = ok ? "凭据已配置 · 数据网关" : "缺数据网关 token"
        }
        channelValidations[key] = .init(ok: ok, detail: detail, at: Date())
    }

    // MARK: - 本地模式应用(耳/口的本机兜底显式开关:本机有方案的能力让用户确认走不走本机)
    /// 语音口:本地模式开=系统语音;关时若当前是系统语音则切回云端情绪语音。
    func applyTTSLocalMode() {
        guard let vm = voiceManager else { return }
        if ttsLocalModeEnabled {
            vm.speechOutputProvider = .appleSpeech
        } else if vm.speechOutputProvider.kind == .appleSpeech {
            vm.speechOutputProvider = .dataNetSpeakerTTS
            vm.speechOutputEndpoint = LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS.defaultEndpoint
        }
    }

    /// 听觉:本地模式开=本机识别(Apple Speech);关=偏好云端实时 ASR 适配器。
    /// 注:当前实时麦克风链路以本机识别为主,云端 ASR 经数据网关用于音频片段感知。
    func applyASRLocalMode() {
        guard let vm = voiceManager else { return }
        if asrLocalModeEnabled {
            vm.transcriptionProvider = .appleSpeech
        } else if vm.transcriptionProvider.kind == .appleSpeech {
            vm.transcriptionProvider = .externalRealtimeAdapter
        }
    }

    /// 校验用小测试图(64×64 纯蓝 PNG base64,内嵌避免跨线程画图)。
    static let channelTestImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsEtiThObwwi+hcEKLNXzWgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgtEA8Fa/ZTA5gAAAABJRU5ErkJggg=="
}
