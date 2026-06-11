import Foundation

enum LingShuVoiceError: LocalizedError {
    case speechRecognizerUnavailable
    case recognitionRequestUnavailable
    case audioInputUnavailable
    case embeddedRuntimeUnavailable(String)
    case embeddedRuntimeLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechRecognizerUnavailable:
            return "系统语音识别当前不可用。"
        case .recognitionRequestUnavailable:
            return "无法创建语音识别请求。"
        case .audioInputUnavailable:
            return "没有检测到可用的麦克风输入。"
        case let .embeddedRuntimeUnavailable(detail):
            return "本地语音模型未就绪：\(detail)"
        case let .embeddedRuntimeLaunchFailed(detail):
            return "本地语音模型启动失败：\(detail)"
        }
    }
}

enum LingShuVoiceTranscriptionProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
    case appleSpeech
    case senseVoiceSherpaONNX
    case funASRService
    case externalRealtimeAdapter

    var label: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .senseVoiceSherpaONNX: "SenseVoice / sherpa-onnx"
        case .funASRService: "FunASR 服务"
        case .externalRealtimeAdapter: "外部实时语音适配器"
        }
    }
}

struct LingShuVoiceTranscriptionProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: LingShuVoiceTranscriptionProviderKind
    var displayName: String
    var deployment: String
    var primaryLanguage: String
    var supportsStreaming: Bool
    var supportsLocalInference: Bool
    var supportsVoiceActivityDetection: Bool
    var supportsSemanticHints: Bool
    var isRuntimeAvailable: Bool
    var note: String

    static let appleSpeech = LingShuVoiceTranscriptionProviderDescriptor(
        id: "apple-speech-zh-cn",
        kind: .appleSpeech,
        displayName: "Apple Speech 中文",
        deployment: "macOS 系统能力",
        primaryLanguage: "zh-CN",
        supportsStreaming: true,
        supportsLocalInference: true,
        supportsVoiceActivityDetection: false,
        supportsSemanticHints: false,
        isRuntimeAvailable: true,
        note: "默认低延迟兜底方案，负责把语音稳定落成文本。"
    )

    static let senseVoiceSherpaONNX = LingShuVoiceTranscriptionProviderDescriptor(
        id: "sensevoice-sherpa-onnx",
        kind: .senseVoiceSherpaONNX,
        displayName: "SenseVoice / sherpa-onnx",
        deployment: "App 内嵌本地模型",
        primaryLanguage: "zh-CN",
        supportsStreaming: true,
        supportsLocalInference: true,
        supportsVoiceActivityDetection: true,
        supportsSemanticHints: true,
        isRuntimeAvailable: false,
        note: "面向中文实时对话的高质量本地理解方案，后续可嵌入 App。"
    )

    static let funASRService = LingShuVoiceTranscriptionProviderDescriptor(
        id: "funasr-local-service",
        kind: .funASRService,
        displayName: "FunASR 本地服务",
        deployment: "本机或内网 ASR 服务",
        primaryLanguage: "zh-CN",
        supportsStreaming: true,
        supportsLocalInference: true,
        supportsVoiceActivityDetection: true,
        supportsSemanticHints: true,
        isRuntimeAvailable: false,
        note: "适合服务化部署 Paraformer / SenseVoice，提供更强中文转写和端点检测。"
    )

    static let externalRealtimeAdapter = LingShuVoiceTranscriptionProviderDescriptor(
        id: "external-realtime-asr",
        kind: .externalRealtimeAdapter,
        displayName: "外部实时语音适配器",
        deployment: "远端或局域网模型",
        primaryLanguage: "zh-CN",
        supportsStreaming: true,
        supportsLocalInference: false,
        supportsVoiceActivityDetection: true,
        supportsSemanticHints: true,
        isRuntimeAvailable: false,
        note: "用于接入自研语音理解模型或多模态实时模型。"
    )

    static let recommendedChineseProviders: [LingShuVoiceTranscriptionProviderDescriptor] = [
        .appleSpeech,
        .senseVoiceSherpaONNX,
        .funASRService,
        .externalRealtimeAdapter
    ]

    func applyingRuntimeAvailability(_ status: LingShuEmbeddedASRRuntimeStatus) -> LingShuVoiceTranscriptionProviderDescriptor {
        var descriptor = self
        descriptor.isRuntimeAvailable = status.isAvailable
        if status.isAvailable {
            descriptor.note = status.activationNote
        } else {
            descriptor.note = status.diagnosticSummary
        }

        return descriptor
    }
}

struct LingShuVoiceTranscriptionResult: Equatable, Sendable {
    var text: String
    var isFinal: Bool
    var confidence: Double?
    var provider: LingShuVoiceTranscriptionProviderDescriptor
    var intentHint: String?
    var timestamp: Date
}

