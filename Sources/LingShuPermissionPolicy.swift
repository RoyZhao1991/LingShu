import Foundation

enum LingShuTaskIntent: Equatable {
    case direct
    case lightweightDevelopment
    case projectExecution
    case capabilityCollaboration
}

struct LingShuPermissionDecision: Equatable {
    var boundary: String
    var allowsFileMutation: Bool
    var requiresHumanApproval: Bool
    var sandboxMode: CodexPermissionMode
}

struct LingShuPermissionPolicy {
    func decide(
        intent: LingShuTaskIntent,
        codexMode: CodexPermissionMode,
        requireHumanApproval: Bool
    ) -> LingShuPermissionDecision {
        switch intent {
        case .projectExecution:
            return .init(
                boundary: "\(codexMode.rawValue)；\(requireHumanApproval ? "高风险动作需人工确认" : "按当前策略自动执行")",
                allowsFileMutation: true,
                requiresHumanApproval: requireHumanApproval,
                sandboxMode: codexMode
            )
        case .lightweightDevelopment:
            return .init(
                boundary: "轻量开发任务；默认不读写项目文件，只产出代码、说明和检查口径",
                allowsFileMutation: false,
                requiresHumanApproval: false,
                sandboxMode: .sandbox
            )
        case .capabilityCollaboration:
            return .init(
                boundary: "分析/规划任务；不进入文件修改，必要时请求用户确认",
                allowsFileMutation: false,
                requiresHumanApproval: requireHumanApproval,
                sandboxMode: .sandbox
            )
        case .direct:
            return .init(
                boundary: "直接回答；不启动执行线程，不操作文件系统",
                allowsFileMutation: false,
                requiresHumanApproval: false,
                sandboxMode: .sandbox
            )
        }
    }
}
