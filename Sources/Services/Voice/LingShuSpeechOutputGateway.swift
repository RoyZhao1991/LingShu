import Foundation

enum LingShuSpeechOutputProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
    case appleSpeech
    case embeddedSherpaONNXTTS
    case dataNetSpeakerTTS
    case indexTTS2Service
    case cosyVoice3Service
    case doubaoService
    case customHTTPService

    var label: String {
        switch self {
        case .appleSpeech: "macOS 系统语音"
        case .embeddedSherpaONNXTTS: "内嵌 sherpa-onnx TTS"
        case .dataNetSpeakerTTS: "数据网关情绪语音"
        case .indexTTS2Service: "IndexTTS2 服务"
        case .cosyVoice3Service: "CosyVoice3 服务"
        case .doubaoService: "豆包/火山云端音色"
        case .customHTTPService: "自定义 TTS 网关"
        }
    }
}

struct LingShuSpeechOutputProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: LingShuSpeechOutputProviderKind
    var displayName: String
    var deployment: String
    var defaultEndpoint: String
    var supportsStreaming: Bool
    var supportsEmotion: Bool
    var supportsVoiceClone: Bool
    var isRuntimeAvailable: Bool
    var note: String

    static let appleSpeech = LingShuSpeechOutputProviderDescriptor(
        id: "apple-speech-output",
        kind: .appleSpeech,
        displayName: "macOS 系统语音（兜底）",
        deployment: "macOS 系统能力",
        defaultEndpoint: "",
        supportsStreaming: false,
        supportsEmotion: false,
        supportsVoiceClone: false,
        isRuntimeAvailable: true,
        note: "本机系统中文语音，**非默认通道**——默认走数据网关情绪男声（dataNetSpeakerTTS）；仅在云端不可用时作兜底。本机若没装中文男声会发出女声（这是系统能力限制，非本通道选择）。"
    )

    static let embeddedSherpaONNXTTS = LingShuSpeechOutputProviderDescriptor(
        id: "embedded-sherpa-onnx-tts",
        kind: .embeddedSherpaONNXTTS,
        displayName: "本地 VITS 中文声线",
        deployment: "App 内嵌本地模型",
        defaultEndpoint: "",
        supportsStreaming: false,
        supportsEmotion: false,
        supportsVoiceClone: false,
        isRuntimeAvailable: false,
        note: "开发环境预置 sherpa-onnx + 中文 VITS 模型；不依赖本机服务，但当前包采样率较低，仅作为完全离线兜底。"
    )

    static let dataNetSpeakerTTS = LingShuSpeechOutputProviderDescriptor(
        id: "datanet-speaker-tts",
        kind: .dataNetSpeakerTTS,
        displayName: "数据网关情绪男声",
        deployment: "数据网络模型网关",
        defaultEndpoint: "https://model-gateway.datanet.bj.cn/v1/perception/swds-speaker-tts",
        supportsStreaming: false,
        supportsEmotion: true,
        supportsVoiceClone: false,
        isRuntimeAvailable: true,
        note: "通过数据网络 swds-speaker-tts 合成中文语音；凭据从 App 包内 RuntimeConfig 读取。"
    )

    static let indexTTS2Service = LingShuSpeechOutputProviderDescriptor(
        id: "indextts2-local-service",
        kind: .indexTTS2Service,
        displayName: "IndexTTS2 本地服务",
        deployment: "本机或内网 TTS 服务",
        defaultEndpoint: "http://127.0.0.1:7860/lingshu/tts",
        supportsStreaming: false,
        supportsEmotion: true,
        supportsVoiceClone: true,
        isRuntimeAvailable: true,
        note: "研究适配项：只有当 IndexTTS2 能随安装包交付或明确配置为外部网关时才启用。"
    )

    static let cosyVoice3Service = LingShuSpeechOutputProviderDescriptor(
        id: "cosyvoice3-local-service",
        kind: .cosyVoice3Service,
        displayName: "CosyVoice3 云端流式服务",
        deployment: "云端或内网 TTS 服务",
        defaultEndpoint: "http://127.0.0.1:50000/lingshu/tts",
        supportsStreaming: true,
        supportsEmotion: true,
        supportsVoiceClone: true,
        isRuntimeAvailable: true,
        note: "适合后续低延迟流式发声，情绪和语速可通过云端模型控制。"
    )

    static let doubaoService = LingShuSpeechOutputProviderDescriptor(
        id: "doubao-cloud-voice",
        kind: .doubaoService,
        displayName: "豆包/火山云端音色",
        deployment: "云端 TTS 服务",
        defaultEndpoint: "https://your-volcengine-tts-adapter.example.com/lingshu/tts",
        supportsStreaming: true,
        supportsEmotion: true,
        supportsVoiceClone: false,
        isRuntimeAvailable: true,
        note: "App 只保留音色 ID 和接口配置，模型权重在云端，体积最小。"
    )

    static let customHTTPService = LingShuSpeechOutputProviderDescriptor(
        id: "custom-http-tts",
        kind: .customHTTPService,
        displayName: "云端 TTS 网关",
        deployment: "HTTP 适配器",
        defaultEndpoint: "",
        supportsStreaming: true,
        supportsEmotion: true,
        supportsVoiceClone: true,
        isRuntimeAvailable: true,
        note: "用于接入后续任意云端语音合成模型；未配置前只显示文字回复，不回退本地声线。"
    )

    /// 语音输出可选项：只列**真实可用**的——本机系统语音 + 已接入的数据网关云端 TTS。
    /// customHTTPService / cosyVoice3Service / doubaoService 是未接入的占位/研究项（空端点、
    /// localhost 未起服务、example.com），不再塞进选择器误导用户（曾出现"只接了一个却有四种"）。
    static let recommendedProviders: [LingShuSpeechOutputProviderDescriptor] = [
        .appleSpeech,
        .dataNetSpeakerTTS
    ]

    func applyingRuntimeAvailability(_ status: LingShuEmbeddedTTSRuntimeStatus) -> LingShuSpeechOutputProviderDescriptor {
        var descriptor = self
        descriptor.isRuntimeAvailable = status.isAvailable
        descriptor.note = status.isAvailable ? status.activationNote : status.diagnosticSummary
        return descriptor
    }
}

struct LingShuSpeechPersona: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    /// 数据网关 TTS 服务端音色 id（实测可用：male_steady/male_elder/female_default/bright/soft）。
    var cloudVoiceId: String
    /// 数据网关 TTS 情绪枚举（neutral/calm/happy/sad/excited/angry/breathy），服务端转 CosyVoice2 控制 token。
    var cloudEmotion: String
    var speakerID: Int   // 仅本地 sherpa TTS（--sid）用
    var speed: Double
    var pitch: Double
    var volume: Double

    static let softDominantMale = LingShuSpeechPersona(
        id: "soft-dominant-young-male",
        displayName: "清晰沉稳男声",
        cloudVoiceId: "male_steady",
        cloudEmotion: "neutral",
        speakerID: 119,
        speed: 0.96,
        pitch: 0.92,
        volume: 1.0
    )

    static let calmJarvisMale = LingShuSpeechPersona(
        id: "calm-jarvis-male",
        displayName: "冷静管家男声",
        cloudVoiceId: "male_steady",   // 实测 F0≈101Hz 男声，贾维斯式沉稳
        cloudEmotion: "calm",
        speakerID: 124,
        speed: 0.94,
        pitch: 0.88,
        volume: 1.0
    )

    static let recommendedPersonas: [LingShuSpeechPersona] = [
        .softDominantMale,
        .calmJarvisMale
    ]
}

/// 数据网关 swds-speaker-tts 的请求体：服务端用枚举式 emotion + 音色 id，
/// 自己转成 CosyVoice2 原生控制 token（别传自然语言提示）。
struct LingShuSpeechSynthesisRequest: Codable, Equatable, Sendable {
    var text: String
    var voiceId: String
    var emotion: String
}

struct LingShuSpeechSynthesisServiceResponse: Decodable, Sendable {
    var audioBase64: String?
    var audioURL: String?

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
        case audioURL = "audio_url"
    }
}

enum LingShuSpeechOutputServiceContract {
    static func request(
        text: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        persona: LingShuSpeechPersona
    ) -> LingShuSpeechSynthesisRequest {
        .init(
            text: text,
            voiceId: persona.cloudVoiceId,
            emotion: persona.cloudEmotion
        )
    }

    static func makeURLRequest(
        endpoint: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        persona: LingShuSpeechPersona,
        text: String,
        apiKey: String = ""
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint), !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LingShuVoiceError.embeddedRuntimeUnavailable("TTS endpoint 未配置")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav, application/json", forHTTPHeaderField: "Accept")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if provider.kind == .dataNetSpeakerTTS {
                request.setValue(apiKey, forHTTPHeaderField: "X-Model-Token")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try JSONEncoder().encode(Self.request(text: text, provider: provider, persona: persona))
        return request
    }
}
