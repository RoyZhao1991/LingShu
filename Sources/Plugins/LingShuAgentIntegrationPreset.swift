import Foundation

/// 本机外部 Agent 的已知接入方式。
///
/// 预设只描述「如何找到 CLI、如何运行、如何读取它自己的权威能力清单」；
/// 能力是否真的存在、已安装且启用，仍由运行时发现结果决定，绝不伪造能力。
struct LingShuAgentIntegrationPreset: Sendable, Equatable {
    let id: String
    let displayName: String
    let aliases: [String]
    let executableCandidates: [String]
    let argsTemplate: [String]
    let role: LingShuAgentPlugin.Role
    let subtitle: String
    let icon: String
    let timeoutSeconds: Int
    let capabilities: AgentCapabilitySpec
    let requiredCapabilityID: String

    func makePlugin(executable: String) -> LingShuAgentPlugin {
        LingShuAgentPlugin(
            id: id,
            displayName: displayName,
            aliases: aliases,
            executable: executable,
            argsTemplate: argsTemplate,
            role: role,
            subtitle: subtitle,
            icon: icon,
            timeoutSeconds: timeoutSeconds,
            capabilities: capabilities
        )
    }

    func requiredCapability(in capabilities: [LingShuAgentCapability]) -> LingShuAgentCapability? {
        capabilities.first {
            $0.agentID == id
                && $0.id.caseInsensitiveCompare(requiredCapabilityID) == .orderedSame
                && $0.installed
                && $0.enabled
        }
    }
}

enum LingShuAgentIntegrationPresetCatalog {
    /// Codex 本身仍经通用外部 Agent 运行器执行；这里只提供一份可复用的接入描述，
    /// Computer Use 的实现、认证和安全策略全部留在 Codex 官方插件内。
    static let codexComputerUse = LingShuAgentIntegrationPreset(
        id: "codex",
        displayName: "Codex",
        aliases: ["codex", "OpenAI Codex"],
        executableCandidates: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "codex",
        ],
        argsTemplate: [
            "exec",
            "--sandbox", "workspace-write",
            "--skip-git-repo-check",
            "{{objective}}",
        ],
        role: .general,
        subtitle: "外部执行方 · 可使用官方 Computer Use 操作 Mac App",
        icon: "macwindow.on.rectangle",
        timeoutSeconds: 900,
        capabilities: AgentCapabilitySpec(
            discover: .init(
                args: ["plugin", "list", "--json", "--available"],
                skillsDir: nil,
                registryFile: nil,
                format: "codex-plugin-list"
            ),
            enable: nil,
            install: nil
        ),
        requiredCapabilityID: "computer-use@openai-bundled"
    )

    static func resolveExecutable(
        for preset: LingShuAgentIntegrationPreset,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        resolveInPath: (String) -> String? = { LingShuAgentPlugin.resolveInPath($0) }
    ) -> String? {
        for candidate in preset.executableCandidates {
            if isExecutable(candidate) { return candidate }
            if let resolved = resolveInPath(candidate), isExecutable(resolved) { return resolved }
        }
        return nil
    }
}
