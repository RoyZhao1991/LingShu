import Foundation

enum LingShuSpeechOutputProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
    case appleSpeech
    case embeddedSherpaONNXTTS
    case indexTTS2Service
    case cosyVoice3Service
    case doubaoService
    case customHTTPService

    var label: String {
        switch self {
        case .appleSpeech: "macOS 系统语音"
        case .embeddedSherpaONNXTTS: "内嵌 sherpa-onnx TTS"
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
        displayName: "macOS 清晰中文男声",
        deployment: "macOS 系统能力",
        defaultEndpoint: "",
        supportsStreaming: false,
        supportsEmotion: false,
        supportsVoiceClone: false,
        isRuntimeAvailable: true,
        note: "使用本机系统中文男声，优先保证吐字清楚和稳定响应；适合作为当前默认声线。"
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

    static let recommendedProviders: [LingShuSpeechOutputProviderDescriptor] = [
        .customHTTPService,
        .cosyVoice3Service,
        .doubaoService
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
    var voiceID: String
    var speakerID: Int
    var personaPrompt: String
    var emotionPrompt: String
    var speed: Double
    var pitch: Double
    var volume: Double

    static let softDominantMale = LingShuSpeechPersona(
        id: "soft-dominant-young-male",
        displayName: "清晰低频男声",
        voiceID: "lingshu_soft_dominant_male",
        speakerID: 119,
        personaPrompt: "年轻男性，声音干净、有亲近感，语气稳定自信，低压迫感但有掌控力；像克制、温柔、可靠的私人中枢。",
        emotionPrompt: "冷静、笃定、轻微关切，回答短句时要自然，有一点笑意但不油腻。",
        speed: 0.96,
        pitch: 0.92,
        volume: 1.0
    )

    static let calmJarvisMale = LingShuSpeechPersona(
        id: "calm-jarvis-male",
        displayName: "冷静管家男声",
        voiceID: "lingshu_calm_jarvis_male",
        speakerID: 124,
        personaPrompt: "成熟男性，克制、专业、清晰，像可靠的智能管家。",
        emotionPrompt: "冷静、准确、少量温度，不夸张。",
        speed: 0.94,
        pitch: 0.88,
        volume: 1.0
    )

    static let recommendedPersonas: [LingShuSpeechPersona] = [
        .softDominantMale,
        .calmJarvisMale
    ]
}

struct LingShuSpeechSynthesisRequest: Codable, Equatable, Sendable {
    var text: String
    var provider: String
    var voiceID: String
    var speakerID: Int
    var personaPrompt: String
    var emotionPrompt: String
    var speed: Double
    var pitch: Double
    var volume: Double
    var responseFormat: String
    var locale: String
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
            provider: provider.kind.rawValue,
            voiceID: persona.voiceID,
            speakerID: persona.speakerID,
            personaPrompt: persona.personaPrompt,
            emotionPrompt: persona.emotionPrompt,
            speed: persona.speed,
            pitch: persona.pitch,
            volume: persona.volume,
            responseFormat: "wav",
            locale: "zh-CN"
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
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Self.request(text: text, provider: provider, persona: persona))
        return request
    }
}

