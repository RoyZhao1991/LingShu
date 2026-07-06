import Foundation

/// 工具自身的副作用类型。
///
/// 这是第 6 站 Agent Loop 的基础契约:Loop 不再靠散落的工具名集合判断"是否改动/能否并行/是否大参数敏感",
/// 而是读取工具声明的元数据。下面的 `inferred` 只为旧工具提供迁移兼容,按**工具 API 标识**归类,不读取用户自然语言。
enum LingShuToolEffect: String, Sendable, Equatable {
    case readOnly
    case write
    case execute
    case network
    case control
    case physical
    case humanInput
    case scaffold
    case unknown
}

enum LingShuToolParallelPolicy: String, Sendable, Equatable {
    /// 无共享副作用,同回合多工具可并发执行。
    case parallelSafe
    /// 有共享状态/副作用/顺序依赖风险,必须串行。
    case serial
}

enum LingShuToolPayloadPolicy: String, Sendable, Equatable {
    case normal
    /// 工具参数可能承载大文本,若必需字段连续空到达,优先指导模型分块传输。
    case largeChunkable
}

enum LingShuToolScaffoldRole: String, Sendable, Equatable {
    case none
    /// 脚手架失败不应阻断真实任务,应提示模型跳过脚手架、继续交付目标。
    case optional
}

struct LingShuToolMetadata: Sendable, Equatable {
    var effect: LingShuToolEffect
    var parallelPolicy: LingShuToolParallelPolicy
    var payloadPolicy: LingShuToolPayloadPolicy
    var scaffoldRole: LingShuToolScaffoldRole
    /// 某些工具将来可按资源 key 做更细粒度并发;当前第 6 站先只区分 serial / parallelSafe。
    var resourceArgumentNames: [String]

    init(
        effect: LingShuToolEffect = .readOnly,
        parallelPolicy: LingShuToolParallelPolicy = .parallelSafe,
        payloadPolicy: LingShuToolPayloadPolicy = .normal,
        scaffoldRole: LingShuToolScaffoldRole = .none,
        resourceArgumentNames: [String] = []
    ) {
        self.effect = effect
        self.parallelPolicy = parallelPolicy
        self.payloadPolicy = payloadPolicy
        self.scaffoldRole = scaffoldRole
        self.resourceArgumentNames = resourceArgumentNames
    }

    var isMutatingProgress: Bool {
        switch effect {
        case .write, .control, .physical:
            return true
        case .readOnly, .execute, .network, .humanInput, .scaffold, .unknown:
            return false
        }
    }

    var isOptionalScaffold: Bool { scaffoldRole == .optional }
    var isLargePayloadSensitive: Bool { payloadPolicy == .largeChunkable }

    /// 旧工具迁移桥:按内核工具 API 标识补元数据。新工具应优先在构造 `LingShuAgentTool` 时显式传 metadata。
    static func inferred(name: String, parametersJSON: String) -> LingShuToolMetadata {
        switch name {
        case "write_file":
            return .init(effect: .write, parallelPolicy: .serial, payloadPolicy: .largeChunkable, resourceArgumentNames: ["path"])
        case "edit_file", "apply_patch":
            return .init(effect: .write, parallelPolicy: .serial, resourceArgumentNames: ["path", "file"])
        case "run_command", "start_long_command":
            return .init(effect: .execute, parallelPolicy: .serial, payloadPolicy: .largeChunkable, resourceArgumentNames: ["cwd", "workingDirectory"])
        case "check_long_command", "list_long_commands":
            return .init(effect: .readOnly, parallelPolicy: .parallelSafe)
        case "cancel_long_command":
            return .init(effect: .control, parallelPolicy: .serial)
        case "ask_user", "ask_choice", "ask_form":
            return .init(effect: .humanInput, parallelPolicy: .serial)
        case "update_plan":
            return .init(effect: .scaffold, parallelPolicy: .serial, scaffoldRole: .optional)
        case "browser_open", "browser_click", "browser_type", "browser_key", "browser_scroll",
             "preview_open", "preview_next", "preview_previous", "preview_fullscreen",
             "computer_click", "computer_type", "computer_key", "computer_scroll", "speak":
            return .init(effect: .control, parallelPolicy: .serial)
        case "fetch_url", "web_search", "discover_skill":
            return .init(effect: .network, parallelPolicy: .parallelSafe)
        default:
            return .init()
        }
    }
}
