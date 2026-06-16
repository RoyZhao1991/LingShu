import Foundation

/// 能力通道校验结果(实测某通道是否真能用)。
struct LingShuChannelValidation: Codable, Equatable, Sendable {
    var ok: Bool
    var detail: String
    var at: Date
}

/// 模型通道 = 带校验的**类型化能力通道**注册表(中枢/视觉/视频/听/语音)。
/// 取向(用户拍板 2026-06-16):TTS/音视频通道也在模型通道里配置;眼耳口鼻嘴内部只**选已配置且校验通过**的通道;
/// 子线程切换 + 各模态选择器都**过滤掉未配置/未校验通过**的通道,不让没真接上的模型出现在可切换列表里。
@MainActor
extension LingShuState {

    // MARK: - 通道 key(纯字符串,nonisolated 便于 UI/测试共用)
    nonisolated static func brainChannelKey(_ provider: String) -> String { "brain:\(provider)" }
    nonisolated static let visionChannelKey = "vision:datanet"
    nonisolated static let videoChannelKey = "video:datanet"
    nonisolated static let asrLocalChannelKey = "asr:local"
    nonisolated static func ttsChannelKey(_ id: String) -> String { "tts:\(id)" }

    func channelValidation(_ key: String) -> LingShuChannelValidation? { channelValidations[key] }
    func isChannelValidated(_ key: String) -> Bool { channelValidations[key]?.ok == true }
    func isChannelValidating(_ key: String) -> Bool { validatingChannels.contains(key) }

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

    // MARK: - 语音合成 TTS 通道(口)
    /// 模型通道里展示/可选的 TTS 通道:数据网关情绪语音(云端,需 token)+ 本机系统语音(始终可用)。
    var ttsChannelDescriptors: [LingShuSpeechOutputProviderDescriptor] {
        [.dataNetSpeakerTTS, .appleSpeech]
    }

    /// TTS 通道**可自定义显示名**(覆盖写死的 displayName);改名持久化。名字写死且不准(如"男声"其实是女声)→ 用户自己改。
    func ttsDisplayName(_ descriptor: LingShuSpeechOutputProviderDescriptor) -> String {
        let custom = ttsChannelNames[descriptor.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom?.isEmpty == false) ? custom! : descriptor.displayName
    }
    func renameTTSChannel(_ descriptorID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { ttsChannelNames[descriptorID] = nil } else { ttsChannelNames[descriptorID] = trimmed }
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
        let adapter = LingShuGatewayAgentModel(
            client: remoteModelClient, provider: providerName, model: mdl, endpoint: ep,
            protocolName: preset.protocolName, apiKey: k, temperature: 0, timeout: 20
        )
        let session = LingShuAgentSession(id: "vbrain-\(UUID().uuidString.prefix(4))", tools: [], model: adapter, maxTurns: 1)
        let result = await session.send("只回复两个字:在的")
        let ok: Bool; let detail: String
        switch result {
        case .completed(let text):
            let clean = LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
            ok = !clean.isEmpty
            detail = ok ? "校验通过 · 模型有回复" : "无回复"
        case .interrupted(let reason):
            ok = false; detail = "连不上 · \(String(reason.prefix(36)))"
        default:
            ok = false; detail = "未通过"
        }
        channelValidations[key] = .init(ok: ok, detail: detail, at: Date())
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

    /// 听(本机 ASR):SFSpeech 本机能力,始终可用。
    func validateASRLocalChannel() {
        channelValidations[Self.asrLocalChannelKey] = .init(ok: true, detail: "本机 SFSpeech · 始终可用", at: Date())
    }

    /// 校验用小测试图(64×64 纯蓝 PNG base64,内嵌避免跨线程画图)。
    static let channelTestImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsEtiThObwwi+hcEKLNXzWgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgtEA8Fa/ZTA5gAAAABJRU5ErkJggg=="
}
