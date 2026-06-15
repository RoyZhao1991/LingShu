import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case command = "运行态势"
    case a2a = "智能体通信"
    case governance = "治理链路"
    case capabilityPackage = "能力包"
    case domains = "能力域"
    case safety = "安全"
    case roadmap = "路线"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .command: "sparkles"
        case .a2a: "point.3.connected.trianglepath.dotted"
        case .governance: "building.columns"
        case .capabilityPackage: "hammer"
        case .domains: "square.grid.3x3"
        case .safety: "checkmark.shield"
        case .roadmap: "map"
        }
    }
}

enum AppSurface: String, CaseIterable, Identifiable {
    case chat = "对话"
    case taskPool = "线程"
    case runtime = "状态"
    case operations = "运维"
    case settings = "配置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chat: "message"
        case .taskPool: "bubble.left.and.bubble.right"
        case .runtime: "waveform.path.ecg"
        case .operations: "building.columns"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum StepState: String {
    case waiting = "待命"
    case running = "执行中"
    case done = "完成"
}

enum AgentRuntimeMode: String {
    case dormant = "待命"
    case planning = "规划"
    case working = "执行"
    case supervising = "监工"
    case correcting = "纠偏"
    case verifying = "验收"
}

enum MissionRuntimePhase: String {
    case idle = "待命"
    case planning = "规划"
    case executing = "执行"
    case supervising = "并行监工"
    case correcting = "纠偏"
    case verifying = "验收"
    case delivering = "交付"
}

enum LingShuCoreState: String {
    case standby = "待机中"
    case thinking = "思考中"
    case executing = "执行中"
    case abnormal = "异常"

    var icon: String {
        switch self {
        case .standby: "circle"
        case .thinking: "brain.head.profile"
        case .executing: "play.circle"
        case .abnormal: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .standby: .white
        case .thinking: .cyan
        case .executing: .lingHolo
        case .abnormal: .orange
        }
    }
}

struct LingShuAgent: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let shortName: String
    let role: String
    let domain: String
    let symbol: String
    let color: Color
    var load: Double
    var state: StepState
    var mode: AgentRuntimeMode = .dormant
    var cadence: String = "-"
    var focus: String = "等待灵枢发令"
    var lastFinding: String = "尚未巡检"
}

struct MissionStep: Identifiable {
    let id = UUID()
    let title: String
    let agent: String
    let detail: String
    var state: StepState
}

struct CapabilityDomain: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let icon: String
    let color: Color
    let maturity: Double
    let modules: [String]
}

struct CapabilityNode: Identifiable {
    let id = UUID()
    let name: String
    let shortName: String
    let role: String
    let deliverable: String
    let supervision: String
    let icon: String
    let color: Color
}

struct CapabilityPhase: Identifiable {
    let id = UUID()
    let title: String
    let owner: String
    let detail: String
    let output: String
    let color: Color
}

enum TaskRuntimeStage: String {
    case dormant = "待机"
    case intake = "受令"
    case memory = "记忆恢复"
    case planning = "计划"
    case permission = "权限裁决"
    case executing = "工具循环"
    case monitoring = "监控"
    case checking = "检查"
    case review = "Review"
    case delivering = "交付"
    case blocked = "异常"
}

struct TaskRuntimeCheck: Identifiable, Equatable {
    let id = UUID()
    let title: String
    var detail: String
    var state: StepState
}

struct TaskRuntimeSnapshot: Equatable {
    var taskID: String
    var stage: TaskRuntimeStage
    var summary: String
    var currentAction: String
    var executionEngine: String
    var permissionBoundary: String
    var memoryStatus: String
    var reviewGate: String
    var checks: [TaskRuntimeCheck]

    static var idle: TaskRuntimeSnapshot {
        .init(
            taskID: "未创建",
            stage: .dormant,
            summary: "等待需要能力协作的任务。",
            currentAction: "无",
            executionEngine: "未选择",
            permissionBoundary: "待裁决",
            memoryStatus: "未检索",
            reviewGate: "未启动",
            checks: [
                .init(title: "上下文", detail: "等待任务进入能力运行时", state: .waiting),
                .init(title: "权限", detail: "等待灵枢裁决", state: .waiting),
                .init(title: "工具循环", detail: "等待执行器接令", state: .waiting),
                .init(title: "验证", detail: "等待产物形成", state: .waiting),
                .init(title: "Review", detail: "等待灵枢验收", state: .waiting)
            ]
        )
    }
}

struct TaskMemoryRecord: Codable, Identifiable {
    let id: String
    var title: String
    var summary: String
    var lastPrompt: String
    var status: String
    var tags: [String]
    var executionRecordID: String?
    var updatedAt: Date
}

struct MainThreadMemoryRecord: Codable, Identifiable {
    let id: String
    var title: String
    var summary: String
    var lastPrompt: String
    var category: String
    var tags: [String]
    var messageCount: Int
    var createdAt: Date
    var updatedAt: Date
    var compressedAt: Date?
}

struct ColdMemoryRecord: Codable, Identifiable {
    let id: String
    var source: String
    var title: String
    var summary: String
    var lastPrompt: String
    var category: String
    var tags: [String]
    var archivedAt: Date
    var updatedAt: Date
}

struct MainThreadMemoryContext {
    var hotMatches: [MainThreadMemoryRecord]
    var coldMatches: [ColdMemoryRecord]
    var shouldLoadHistory: Bool
    var status: String

    var promptHint: String {
        let hotText = hotMatches.prefix(3).map { record in
            "- 热记忆：\(record.title)；类别：\(record.category)；标签：\(record.tags.joined(separator: "、"))；摘要：\(record.summary)"
        }.joined(separator: "\n")
        let coldText = coldMatches.prefix(3).map { record in
            "- 冷备：\(record.title)；来源：\(record.source)；类别：\(record.category)；标签：\(record.tags.joined(separator: "、"))；摘要：\(record.summary)"
        }.joined(separator: "\n")
        let combined = [hotText, coldText].filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? "未命中可用历史记忆。" : combined
    }
}

struct ModelProviderPreset: Identifiable {
    let id: String
    let name: String
    let region: String
    let category: String
    let endpoint: String
    let protocolName: String
    let authMode: String
    let defaultModels: [String]
    let note: String
    /// 是否原生多模态（图片可直接喂主模型）。
    /// false（如 MiniMax M3）→ 图片走云视觉解析成文字再注入（零留存）；
    /// true（如 KIMI K2.6 这类原生多模态）→ 图片内联进消息，和 codex/claude 架构统一。
    /// 换原生多模态模型时把这个置 true 即可，不必改调用链。
    var supportsNativeMultimodal: Bool = false

    var displayName: String {
        "\(name) · \(region)"
    }

    static let codexAuth = ModelProviderPreset(
        id: "codex-auth",
        name: "Codex Auth",
        region: "OpenAI 登录",
        category: "授权通道",
        endpoint: "codex://local-cli",
        protocolName: "Codex CLI",
        authMode: "ChatGPT / Codex 登录",
        defaultModels: ["gpt-5.5", "Codex 默认模型"],
        note: "复用本机 Codex 登录状态，不读取 token。"
    )

    static let minimaxOfficial = ModelProviderPreset(
        id: "minimax-official",
        name: "MiniMax 官方",
        region: "国内·官方直连",
        category: "纯推理通道",
        endpoint: "https://api.minimaxi.com/v1",
        protocolName: "OpenAI Chat",
        authMode: "API Key",
        defaultModels: ["MiniMax-M3", "MiniMax-M2.7"],
        note: "MiniMax 官方直连，纯文本推理、标准流式、无 agent 框架注入（prompt 基数约 178 而非网关的 1.34 万）。文本与中枢调度走这里；图片/音频/视频感知仍走数据网络网关专项接口。"
    )

    static let dataNetGateway = ModelProviderPreset(
        id: "datanet-gateway",
        name: "数据网络网关",
        region: "国内·算力中心",
        category: "统一网关",
        endpoint: "https://model-gateway.datanet.bj.cn/v1",
        protocolName: "OpenAI Chat",
        authMode: "网关 Token",
        defaultModels: ["swds-multimodal-parse", "swds-text-parse"],
        note: "数据增值协作网络算力中心统一网关：图片/音频/视频走 /v1/perception 专项接口。注意：其 chat 端点每次注入约 1.34 万 token 的 agent 框架，文本推理建议优先用 MiniMax 官方直连。"
    )

    static let apiCatalog: [ModelProviderPreset] = [
        minimaxOfficial,
        dataNetGateway,
        .init(id: "openai", name: "OpenAI", region: "海外", category: "原厂 API", endpoint: "https://api.openai.com/v1", protocolName: "Responses / OpenAI", authMode: "API Key", defaultModels: ["gpt-5.5", "gpt-5", "gpt-4.1", "gpt-4o"], note: "适合作为灵枢主中枢和复杂推理模型。"),
        .init(id: "azure-openai", name: "Azure OpenAI", region: "海外/企业", category: "云厂商托管", endpoint: "https://{resource}.openai.azure.com/openai", protocolName: "Azure OpenAI", authMode: "API Key / Entra ID", defaultModels: ["gpt-5.5", "gpt-5", "gpt-4.1", "gpt-4o"], note: "适合企业账号、私有网络和合规场景。"),
        .init(id: "anthropic", name: "Anthropic Claude", region: "海外", category: "原厂 API", endpoint: "https://api.anthropic.com/v1", protocolName: "Anthropic", authMode: "API Key", defaultModels: ["claude-opus-4.1", "claude-opus-4", "claude-sonnet-4.5", "claude-haiku-4.5"], note: "适合长文档、规划、审查和高质量写作。"),
        .init(id: "google-gemini", name: "Google Gemini", region: "海外", category: "原厂 API", endpoint: "https://generativelanguage.googleapis.com/v1beta/openai", protocolName: "OpenAI 兼容 / Gemini", authMode: "API Key", defaultModels: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"], note: "适合多模态、长上下文和低延迟场景。"),
        .init(id: "xai", name: "xAI Grok", region: "海外", category: "OpenAI 兼容", endpoint: "https://api.x.ai/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["grok-4", "grok-3", "grok-3-mini"], note: "适合实时问答和通用助理分支。"),
        .init(id: "mistral", name: "Mistral AI", region: "欧洲", category: "原厂 API", endpoint: "https://api.mistral.ai/v1", protocolName: "OpenAI 兼容 / Mistral", authMode: "API Key", defaultModels: ["mistral-large-latest", "codestral-latest", "ministral-8b-latest"], note: "适合代码、欧洲部署和轻量模型。"),
        .init(id: "cohere", name: "Cohere", region: "海外", category: "原厂 API", endpoint: "https://api.cohere.com/v2", protocolName: "Cohere", authMode: "API Key", defaultModels: ["command-a", "command-r-plus", "command-r"], note: "适合企业检索增强和工具流。"),
        .init(id: "perplexity", name: "Perplexity", region: "海外", category: "搜索增强", endpoint: "https://api.perplexity.ai", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["sonar-pro", "sonar", "sonar-reasoning-pro"], note: "适合联网检索型专家智能体。"),
        .init(id: "groq", name: "Groq", region: "海外", category: "高速推理", endpoint: "https://api.groq.com/openai/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "mixtral-8x7b"], note: "适合低延迟并发子智能体。"),
        .init(id: "openrouter", name: "OpenRouter", region: "聚合", category: "模型聚合", endpoint: "https://openrouter.ai/api/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["openai/gpt-5", "anthropic/claude-sonnet-4.5", "google/gemini-2.5-pro", "deepseek/deepseek-chat"], note: "适合一套接口切换多家模型。"),
        .init(id: "together", name: "Together AI", region: "海外/开源", category: "模型托管", endpoint: "https://api.together.xyz/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8", "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8", "deepseek-ai/DeepSeek-V3"], note: "适合开源模型和批量推理。"),
        .init(id: "aws-bedrock", name: "AWS Bedrock", region: "海外/企业", category: "云厂商托管", endpoint: "bedrock://{region}/{profile}", protocolName: "Bedrock SDK", authMode: "AWS IAM", defaultModels: ["anthropic.claude-sonnet-4", "amazon.nova-pro", "meta.llama4"], note: "适合企业云和多模型治理。"),
        .init(id: "vertex-ai", name: "Google Vertex AI", region: "海外/企业", category: "云厂商托管", endpoint: "vertex://{project}/{location}", protocolName: "Vertex AI", authMode: "Google IAM", defaultModels: ["gemini-2.5-pro", "gemini-2.5-flash"], note: "适合 GCP 企业部署。"),

        .init(id: "deepseek", name: "DeepSeek", region: "国内", category: "OpenAI 兼容", endpoint: "https://api.deepseek.com", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["deepseek-chat", "deepseek-reasoner"], note: "适合中文推理、代码和成本敏感任务。"),
        .init(id: "qwen-dashscope", name: "阿里通义千问 / 百炼", region: "国内", category: "OpenAI 兼容", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", protocolName: "OpenAI 兼容 / DashScope", authMode: "API Key", defaultModels: ["qwen-max", "qwen-plus", "qwen-turbo", "qwen3-coder-plus"], note: "适合中文、多模态、企业百炼平台。"),
        .init(id: "kimi", name: "Moonshot Kimi", region: "国内", category: "OpenAI 兼容", endpoint: "https://api.moonshot.cn/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["kimi-k2-0905-preview", "kimi-k2-0711-preview", "moonshot-v1-128k", "moonshot-v1-32k"], note: "适合长文本、中文材料分析和研究助手。"),
        .init(id: "zhipu", name: "智谱 GLM", region: "国内", category: "OpenAI 兼容", endpoint: "https://open.bigmodel.cn/api/paas/v4", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["glm-4.5", "glm-4.5-air", "glm-4-plus", "glm-z1-air"], note: "适合中文通用、工具调用和政企场景。"),
        .init(id: "doubao", name: "火山引擎豆包", region: "国内", category: "OpenAI 兼容", endpoint: "https://ark.cn-beijing.volces.com/api/v3", protocolName: "OpenAI 兼容 / Ark", authMode: "API Key", defaultModels: ["doubao-seed-1.6", "doubao-1.5-pro", "doubao-1.5-lite"], note: "适合国内低延迟、多模态和企业接入。"),
        .init(id: "hunyuan", name: "腾讯混元", region: "国内", category: "OpenAI 兼容", endpoint: "https://api.hunyuan.cloud.tencent.com/v1", protocolName: "OpenAI 兼容 / 腾讯云", authMode: "API Key", defaultModels: ["hunyuan-turbos-latest", "hunyuan-large", "hunyuan-standard"], note: "适合腾讯云生态和中文任务。"),
        .init(id: "baidu-qianfan", name: "百度文心 / 千帆", region: "国内", category: "云厂商托管", endpoint: "https://qianfan.baidubce.com/v2", protocolName: "千帆 / OpenAI 兼容", authMode: "API Key", defaultModels: ["ernie-4.5-turbo", "ernie-4.0-turbo", "ernie-x1-turbo"], note: "适合百度云生态、中文知识和企业应用。"),
        .init(id: "minimax", name: "MiniMax", region: "国内", category: "OpenAI 兼容", endpoint: "https://api.minimax.chat/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["MiniMax-M1", "MiniMax-Text-01", "abab6.5s-chat"], note: "适合角色对话、语音和多模态扩展。"),
        .init(id: "stepfun", name: "阶跃星辰 StepFun", region: "国内", category: "OpenAI 兼容", endpoint: "https://api.stepfun.com/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["step-2-16k", "step-1-256k", "step-1v-32k"], note: "适合长上下文和多模态实验。"),
        .init(id: "yi", name: "零一万物 Yi", region: "国内", category: "OpenAI 兼容", endpoint: "https://api.lingyiwanwu.com/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["yi-large", "yi-medium", "yi-spark"], note: "适合中文通用和中小成本模型。"),
        .init(id: "baichuan", name: "百川智能", region: "国内", category: "OpenAI 兼容", endpoint: "https://api.baichuan-ai.com/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["Baichuan4", "Baichuan3-Turbo", "Baichuan3-Turbo-128k"], note: "适合中文知识、企业客服和行业应用。"),
        .init(id: "siliconflow", name: "硅基流动 SiliconFlow", region: "国内/聚合", category: "模型聚合", endpoint: "https://api.siliconflow.cn/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["deepseek-ai/DeepSeek-V3", "Qwen/Qwen3-Coder", "zai-org/GLM-4.5"], note: "适合国内开源模型聚合和成本控制。"),
        .init(id: "modelscope", name: "魔搭 ModelScope", region: "国内/开源", category: "模型托管", endpoint: "https://api-inference.modelscope.cn/v1", protocolName: "OpenAI 兼容", authMode: "API Key", defaultModels: ["Qwen/Qwen3-Coder-480B-A35B-Instruct", "deepseek-ai/DeepSeek-V3", "ZhipuAI/GLM-4.5"], note: "适合开源模型实验和国内托管。"),

        .init(id: "ollama", name: "Ollama", region: "本地", category: "本地模型", endpoint: "http://localhost:11434/v1", protocolName: "OpenAI 兼容", authMode: "无 / 本地", defaultModels: ["qwen3:8b", "qwen2.5:7b-instruct", "deepseek-r1:8b", "llama3.3"], note: "适合中文离线对话、隐私和低成本本机智能体。"),
        .init(id: "lm-studio", name: "LM Studio", region: "本地", category: "本地模型", endpoint: "http://localhost:1234/v1", protocolName: "OpenAI 兼容", authMode: "无 / 本地", defaultModels: ["qwen3", "qwen2.5-7b-instruct", "deepseek-r1", "local-model"], note: "适合桌面本地中文模型调试。"),
        .init(id: "vllm", name: "vLLM / 私有网关", region: "本地/私有云", category: "自托管", endpoint: "http://localhost:8000/v1", protocolName: "OpenAI 兼容", authMode: "可选 API Key", defaultModels: ["Qwen3-Coder", "Qwen2.5-72B-Instruct", "DeepSeek-V3", "served-model-name"], note: "适合自托管 GPU、内网中文模型和研究集群。"),
        .init(id: "custom-compatible", name: "自定义兼容接口", region: "任意", category: "自定义", endpoint: "https://your-gateway.example.com/v1", protocolName: "OpenAI 兼容 / 自定义", authMode: "按网关配置", defaultModels: ["custom-model"], note: "用于未来新模型、学校/企业私有网关和代理服务。")
    ]

    static let catalog: [ModelProviderPreset] = [codexAuth] + apiCatalog
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let speaker: String
    var text: String
    let isUser: Bool
    var isLoading: Bool
    var taskRecordID: String?
    var createdAt: Date
    /// 灵枢请用户在有限选项中做选择时的结构化选项；nil 表示普通消息。
    var choices: CodexRouteChoicePrompt?
    /// 用户已选中的选项标签（选过之后卡片置为已解决，不再可点）。
    var resolvedChoice: String?
    /// 思考中气泡上实时滚动的推理预览（流式 <think> 增量的尾部）；定稿时清空，不进历史。
    var thinkingPreview: String?
    /// 本条用户消息随附的附件文件名(发送时携带的)；nil/空=无附件。Optional 保证旧持久化记录向后兼容解码。
    var attachmentNames: [String]?

    init(
        id: UUID = UUID(),
        speaker: String,
        text: String,
        isUser: Bool,
        isLoading: Bool = false,
        taskRecordID: String? = nil,
        createdAt: Date = Date(),
        choices: CodexRouteChoicePrompt? = nil,
        resolvedChoice: String? = nil,
        thinkingPreview: String? = nil,
        attachmentNames: [String]? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.isUser = isUser
        self.isLoading = isLoading
        self.taskRecordID = taskRecordID
        self.createdAt = createdAt
        self.choices = choices
        self.resolvedChoice = resolvedChoice
        self.thinkingPreview = thinkingPreview
        self.attachmentNames = attachmentNames
    }
}

struct SupervisorEvent: Identifiable {
    let id = UUID()
    let agent: String
    let severity: String
    let title: String
    let detail: String
    let tick: Int
}

enum LingShuTraceKind: String {
    case system = "系统"
    case route = "路由"
    case runtime = "运行时"
    case model = "模型"
    case agent = "Agent"
    case tool = "工具"
    case warning = "告警"
    case result = "结果"
}

struct ExecutionTraceEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let kind: LingShuTraceKind
    let actor: String
    let title: String
    let detail: String
    let isStream: Bool

    var displayTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}
