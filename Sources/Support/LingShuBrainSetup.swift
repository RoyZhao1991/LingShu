import Foundation

enum LingShuBrainSetupPhase: Equatable {
    case unchecked
    case checking
    case required(reason: String)
    case ready

    var shouldPresentWizard: Bool {
        if case .required = self { return true }
        return false
    }

    var reason: String {
        if case .required(let reason) = self { return reason }
        return ""
    }
}

enum LingShuBrainSetupRoute: String, CaseIterable, Identifiable {
    case openAI
    case claude
    case deepSeek
    case minimax
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "GPT"
        case .claude: "Claude"
        case .deepSeek: "DeepSeek"
        case .minimax: "MiniMax M3"
        case .custom: "其他服务"
        }
    }

    var englishTitle: String {
        switch self {
        case .openAI: "GPT"
        case .claude: "Claude"
        case .deepSeek: "DeepSeek"
        case .minimax: "MiniMax M3"
        case .custom: "Other"
        }
    }

    var subtitle: String {
        switch self {
        case .openAI: "OpenAI 官方"
        case .claude: "Anthropic 官方"
        case .deepSeek: "官方 API"
        case .minimax: "官方 API"
        case .custom: "兼容接口"
        }
    }

    var englishSubtitle: String {
        switch self {
        case .openAI: "Official OpenAI"
        case .claude: "Official Anthropic"
        case .deepSeek, .minimax: "Official API"
        case .custom: "Compatible endpoint"
        }
    }

    var systemImage: String {
        switch self {
        case .openAI: "sparkles"
        case .claude: "text.bubble"
        case .deepSeek: "brain.head.profile"
        case .minimax: "waveform.path.ecg"
        case .custom: "link"
        }
    }

    var preset: ModelProviderPreset? {
        let id: String
        switch self {
        case .openAI: id = "openai"
        case .claude: id = "anthropic"
        case .deepSeek: id = "deepseek"
        case .minimax: id = "minimax-official"
        case .custom: id = "custom-compatible"
        }
        return ModelProviderPreset.apiCatalog.first { $0.id == id }
    }

    var defaultModel: String {
        guard let preset else { return "" }
        if self == .claude,
           let sonnet = preset.defaultModels.first(where: { $0.localizedCaseInsensitiveContains("sonnet") }) {
            return sonnet
        }
        return preset.defaultModels.first ?? ""
    }

    var modelOptions: [String] {
        preset?.defaultModels ?? []
    }
}

struct LingShuBrainSetupConfiguration: Equatable, Sendable {
    var providerID: String
    var providerName: String
    var endpoint: String
    var model: String
    var protocolName: String
    var apiKey: String

    var inputError: LingShuBrainSetupInputError? {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return .missingToken }
        guard !trimmedModel.isEmpty else { return .missingModel }
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return .invalidEndpoint
        }
        return nil
    }

    static func make(
        route: LingShuBrainSetupRoute,
        token: String,
        selectedModel: String,
        customEndpoint: String,
        customModel: String
    ) throws -> LingShuBrainSetupConfiguration {
        guard let preset = route.preset else { throw LingShuBrainSetupInputError.missingProvider }
        let configuration = LingShuBrainSetupConfiguration(
            providerID: preset.id,
            providerName: preset.name,
            endpoint: route == .custom ? customEndpoint : preset.endpoint,
            model: route == .custom
                ? customModel
                : (selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? route.defaultModel : selectedModel),
            protocolName: preset.protocolName,
            apiKey: token
        )
        if let error = configuration.inputError { throw error }
        return configuration
    }
}

enum LingShuBrainSetupInputError: LocalizedError, Equatable {
    case missingProvider
    case missingToken
    case missingModel
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .missingProvider: "请选择一个主脑服务。"
        case .missingToken: "请填写访问 Token。"
        case .missingModel: "请填写模型名称。"
        case .invalidEndpoint: "接口地址需要是完整的 http 或 https 地址。"
        }
    }

    var englishDescription: String {
        switch self {
        case .missingProvider: "Choose a brain provider."
        case .missingToken: "Enter an access token."
        case .missingModel: "Enter a model name."
        case .invalidEndpoint: "The endpoint must be a complete HTTP or HTTPS URL."
        }
    }
}
