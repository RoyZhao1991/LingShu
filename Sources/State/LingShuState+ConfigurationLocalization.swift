extension LingShuInvocablePlugin {
    func localizedDisplayName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return displayName }
        if id == "present" || displayName == "演示与答疑" {
            return "Presentation & Q&A"
        }
        return displayName
    }
}

extension LingShuPerceptionProviderMode {
    func localizedLabel(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return label }
        switch self {
        case .local: return "Local Analysis"
        case .realtimeModel: return "Direct Model"
        case .externalAdapter: return "External Adapter"
        }
    }
}

extension LingShuPerceptionRoute {
    func localizedDisplayName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return displayName }
        if id == Self.local.id { return "Local Analysis" }
        return LingShuState.containsHan(displayName) ? mode.localizedLabel(language: language) : displayName
    }
}

extension LingShuSpeechPersona {
    func localizedDisplayName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return displayName }
        switch id {
        case "soft-dominant-young-male": return "Clear, Steady Male Voice"
        case "calm-jarvis-male": return "Calm Butler Voice"
        default: return LingShuState.containsHan(displayName) ? "Custom Voice" : displayName
        }
    }
}

extension LingShuEmbeddedASRRuntimeStatus {
    func localizedCompactDiagnostic(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return compactDiagnostic }
        guard !isAvailable else { return "Ready" }
        return missingItems.isEmpty ? "Not Installed" : "Missing Components"
    }
}

extension LingShuVoiceTranscriptionProviderDescriptor {
    func localizedDisplayName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return displayName }
        switch id {
        case "apple-speech-zh-cn": return "Apple Speech · Chinese"
        case "sensevoice-sherpa-onnx": return "SenseVoice / sherpa-onnx"
        case "funasr-local-service": return "FunASR Local Service"
        case "external-realtime-asr": return "External Real-time Speech Adapter"
        default: return LingShuState.containsHan(displayName) ? "Speech Recognition Provider" : displayName
        }
    }

    func localizedDeployment(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return deployment }
        switch id {
        case "apple-speech-zh-cn": return "macOS System Capability"
        case "sensevoice-sherpa-onnx": return "Embedded Local Model"
        case "funasr-local-service": return "Local or Intranet ASR Service"
        case "external-realtime-asr": return "Remote or LAN Model"
        default: return LingShuState.containsHan(deployment) ? "Custom Deployment" : deployment
        }
    }

    func localizedNote(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return note }
        if note.contains("已就绪") { return "Runtime ready." }
        if note.contains("未就绪") || note.contains("缺少") { return "Runtime unavailable; check the local model installation." }
        switch id {
        case "apple-speech-zh-cn": return "Low-latency system fallback for reliable speech-to-text."
        case "sensevoice-sherpa-onnx": return "High-quality local speech understanding optimized for real-time Chinese conversation."
        case "funasr-local-service": return "Service deployment for Paraformer or SenseVoice with stronger transcription and endpoint detection."
        case "external-realtime-asr": return "Connect a custom speech model or a multimodal real-time model."
        default: return LingShuState.containsHan(note) ? "Speech recognition provider." : note
        }
    }
}

extension LingShuSpeechOutputProviderDescriptor {
    func localizedDisplayName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return displayName }
        switch id {
        case "apple-speech-output": return "macOS System Voice · Fallback"
        case "embedded-sherpa-onnx-tts": return "Local VITS Chinese Voice"
        case "datanet-speaker-tts": return "Data Gateway Expressive Voice"
        case "indextts2-local-service": return "IndexTTS2 Local Service"
        case "cosyvoice3-local-service": return "CosyVoice3 Cloud Streaming"
        case "doubao-cloud-voice": return "Doubao / Volcano Cloud Voice"
        case "custom-http-tts": return "Cloud TTS Gateway"
        default: return LingShuState.containsHan(displayName) ? "Speech Output Provider" : displayName
        }
    }

    func localizedDeployment(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return deployment }
        switch id {
        case "apple-speech-output": return "macOS System Capability"
        case "embedded-sherpa-onnx-tts": return "Embedded Local Model"
        case "datanet-speaker-tts": return "Data Model Gateway"
        case "indextts2-local-service": return "Local or Intranet TTS Service"
        case "cosyvoice3-local-service": return "Cloud or Intranet TTS Service"
        case "doubao-cloud-voice": return "Cloud TTS Service"
        case "custom-http-tts": return "HTTP Adapter"
        default: return LingShuState.containsHan(deployment) ? "Custom Deployment" : deployment
        }
    }

    func localizedNote(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return note }
        if note.contains("已就绪") { return "Runtime ready." }
        if note.contains("未就绪") || note.contains("缺少") {
            return "Runtime unavailable; check the voice model installation."
        }
        switch id {
        case "apple-speech-output": return "System speech fallback used when the preferred remote voice is unavailable."
        case "embedded-sherpa-onnx-tts": return "Fully offline local fallback powered by an embedded Chinese VITS model."
        case "datanet-speaker-tts": return "Expressive Chinese speech through the configured data-model gateway."
        case "indextts2-local-service": return "Research adapter for an explicitly configured IndexTTS2 service."
        case "cosyvoice3-local-service": return "Low-latency streaming speech with model-controlled emotion and pace."
        case "doubao-cloud-voice": return "Cloud voice configuration with a small local footprint."
        case "custom-http-tts": return "Connect any compatible cloud speech synthesis service."
        default: return LingShuState.containsHan(note) ? "Speech output provider." : note
        }
    }
}

extension ModelProviderPreset {
    func localizedName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return name }
        let names: [String: String] = [
            "minimax-official": "MiniMax Official",
            "datanet-gateway": "Data Network Gateway",
            "qwen-dashscope": "Alibaba Qwen / Bailian",
            "zhipu": "Zhipu GLM",
            "zhipu-coding": "Zhipu GLM Coding",
            "doubao": "Volcano Engine Doubao",
            "hunyuan": "Tencent Hunyuan",
            "baidu-qianfan": "Baidu ERNIE / Qianfan",
            "stepfun": "StepFun",
            "yi": "01.AI Yi",
            "baichuan": "Baichuan",
            "siliconflow": "SiliconFlow",
            "modelscope": "ModelScope",
            "custom-compatible": "Custom Compatible Endpoint"
        ]
        return names[id] ?? name
    }

    func localizedRegion(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return region }
        return Self.englishRegions[region] ?? "Other"
    }

    func localizedCategory(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return category }
        return Self.englishCategories[category] ?? "Model Service"
    }

    func localizedProtocolName(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return protocolName }
        return Self.englishProtocols[protocolName] ?? protocolName
    }

    func localizedAuthMode(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return authMode }
        return Self.englishAuthModes[authMode] ?? authMode
    }

    func localizedNote(language: LingShuVoiceLanguage) -> String {
        guard language == .english else { return note }
        switch id {
        case "minimax-official":
            return "Direct MiniMax API with standard streaming and automatic multimodal fallback."
        case "datanet-gateway":
            return "Unified data-network gateway for image, audio, and video perception services."
        case "custom-compatible":
            return "Use this for a private, enterprise, school, or future OpenAI-compatible gateway."
        case "ollama", "lm-studio", "vllm":
            return "Local or self-hosted model channel for private and offline workflows."
        default:
            return "\(localizedName(language: .english)) model channel using \(localizedProtocolName(language: .english))."
        }
    }

    func displayName(language: LingShuVoiceLanguage) -> String {
        "\(localizedName(language: language)) · \(localizedRegion(language: language))"
    }

    private static let englishRegions: [String: String] = [
        "国内·官方直连": "China · Direct API", "国内·算力中心": "China · Compute Center",
        "海外": "International", "海外/企业": "International / Enterprise", "欧洲": "Europe",
        "聚合": "Aggregator", "海外/开源": "International / Open Source", "国内": "China",
        "国内/聚合": "China / Aggregator", "国内/开源": "China / Open Source", "本地": "Local",
        "本地/私有云": "Local / Private Cloud", "任意": "Any"
    ]

    private static let englishCategories: [String: String] = [
        "原厂 API": "First-party API", "云厂商托管": "Cloud Managed", "OpenAI 兼容": "OpenAI Compatible",
        "统一网关": "Unified Gateway", "搜索增强": "Search Enhanced", "高速推理": "High-speed Inference",
        "模型聚合": "Model Aggregator", "模型托管": "Model Hosting", "本地模型": "Local Model",
        "自托管": "Self-hosted", "自定义": "Custom"
    ]

    private static let englishProtocols: [String: String] = [
        "OpenAI 兼容": "OpenAI Compatible", "OpenAI 兼容 / Gemini": "OpenAI Compatible / Gemini",
        "OpenAI 兼容 / Mistral": "OpenAI Compatible / Mistral", "OpenAI 兼容 / DashScope": "OpenAI Compatible / DashScope",
        "OpenAI 兼容 / Coding Plan": "OpenAI Compatible / Coding Plan", "OpenAI 兼容 / Ark": "OpenAI Compatible / Ark",
        "OpenAI 兼容 / 腾讯云": "OpenAI Compatible / Tencent Cloud", "千帆 / OpenAI 兼容": "Qianfan / OpenAI Compatible",
        "OpenAI 兼容 / 自定义": "OpenAI Compatible / Custom"
    ]

    private static let englishAuthModes: [String: String] = [
        "网关 Token": "Gateway Token", "无 / 本地": "None / Local", "可选 API Key": "Optional API Key",
        "按网关配置": "Gateway-defined"
    ]
}
