import Foundation

struct LingShuAutonomousEnvironmentInput: Equatable {
    var workingDirectory: String
    var modelProvider: String
    var modelName: String
    var isModelConnected: Bool
    var modelConnectionState: String
    var codexPermissionMode: CodexPermissionMode
    var requireHumanApproval: Bool
    var permissionLevel: LingShuAutonomousPermissionLevel
    var voiceOutputEnabled: Bool
    var voiceWakeListeningEnabled: Bool
    var memoryDigestAvailable: Bool
    var onlineAgentCount: Int
    var runningAgentCount: Int
    var pendingAgentCount: Int
}

struct LingShuAutonomousEnvironmentProbe {
    func run(input: LingShuAutonomousEnvironmentInput, now: Date = Date()) -> LingShuAutonomousEnvironmentReport {
        let workingDirectory = input.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default
        let directoryExists = !workingDirectory.isEmpty && fileManager.fileExists(atPath: workingDirectory)
        let artifactRoot = directoryExists
            ? URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent("LingShuAutonomousRuns", isDirectory: true)
            : nil

        var items: [LingShuAutonomousCheckItem] = []
        items.append(.init(
            id: "workspace",
            title: "工作区",
            level: directoryExists ? .pass : .failed,
            detail: directoryExists ? "可访问：\(workingDirectory)" : "工作目录不可用：\(workingDirectory.isEmpty ? "未配置" : workingDirectory)"
        ))
        items.append(.init(
            id: "artifact-root",
            title: "产出物目录",
            level: artifactRoot.map { canPrepareDirectory($0) } == true ? .pass : .failed,
            detail: artifactRoot.map { "独立运行产出将落在：\($0.path)" } ?? "缺少可用工作区，无法准备产出物目录。"
        ))
        items.append(.init(
            id: "model",
            title: "模型通道",
            level: input.isModelConnected ? .pass : .failed,
            detail: input.isModelConnected
                ? "\(input.modelProvider) / \(input.modelName) 已连接"
                : "模型不可用：\(input.modelConnectionState)"
        ))
        items.append(.init(
            id: "permission",
            title: "权限边界",
            level: permissionLevel(input),
            detail: permissionDetail(input)
        ))
        items.append(.init(
            id: "memory",
            title: "记忆链路",
            level: input.memoryDigestAvailable ? .pass : .warning,
            detail: input.memoryDigestAvailable ? "热历史、冷备摘要和上下文压缩已接入。" : "暂无冷备摘要；仍可使用热历史和主线程记忆。"
        ))
        items.append(.init(
            id: "voice",
            title: "语音输出",
            level: input.voiceOutputEnabled ? .pass : .warning,
            detail: input.voiceOutputEnabled ? "语音输出已开启，可用于自主汇报或答疑。" : "语音输出关闭；独立运行会降级为文本/屏幕提示。"
        ))
        items.append(.init(
            id: "wake",
            title: "语音入口",
            level: input.voiceWakeListeningEnabled ? .pass : .warning,
            detail: input.voiceWakeListeningEnabled ? "收声入口待机，可接入触发词与实时对话。" : "收声入口未启用；需要现场答疑时应提前开启。"
        ))
        items.append(.init(
            id: "agents",
            title: "能力池",
            level: input.onlineAgentCount > 0 ? .pass : .warning,
            detail: "在线 \(input.onlineAgentCount)，运行 \(input.runningAgentCount)，待启动 \(input.pendingAgentCount)。"
        ))

        return .init(generatedAt: now, items: items)
    }

    private func canPrepareDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private func permissionLevel(_ input: LingShuAutonomousEnvironmentInput) -> LingShuAutonomousCheckLevel {
        switch input.permissionLevel {
        case .observe:
            return .warning
        case .delegated:
            return .pass
        case .full:
            return input.codexPermissionMode == .fullAccess ? .pass : .warning
        }
    }

    private func permissionDetail(_ input: LingShuAutonomousEnvironmentInput) -> String {
        switch input.permissionLevel {
        case .observe:
            return "当前为观察模式：不会主动修改文件或控制应用。"
        case .delegated:
            return input.requireHumanApproval ? "代理模式：可推进低风险动作，高风险动作需确认。" : "代理模式：按当前策略自动推进授权动作。"
        case .full:
            return input.codexPermissionMode == .fullAccess
                ? "完整授权：Codex/工具层已处于完整权限，仍保留一键接管。"
                : "已选择完整授权，但底层 Codex 仍是沙箱权限；系统级动作会降级。"
        }
    }
}
