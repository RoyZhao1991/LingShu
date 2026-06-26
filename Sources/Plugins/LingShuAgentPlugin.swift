import Foundation

/// **动态注册的 agent 插件**(可插拔自进化的一种):本机某个外部 CLI agent(codex / claude / 其它),
/// 被**显式告知可用 → 注册**后入插件库,之后可 `@别名` 声明式调用、参与编排(@Codex 写码 @Claude 审核)。
///
/// 设计取向(用户定调 2026-06-25):**不是灵枢启动时自检**,而是「告诉灵枢本机有 X → 灵枢注册 X 成 agent 插件 → 能用」。
/// 注册 = 写一份描述符进插件库(`~/Library/Application Support/LingShu/AgentPlugins/*.json`,跨重启持久)。
/// 执行 = 按 `argsTemplate` 把 `{{objective}}` 填进去、跑这个 CLI(不再为 codex/claude 写专门的桥;任何 CLI agent 同一套)。
struct LingShuAgentPlugin: Codable, Identifiable, Sendable, Equatable {
    let id: String              // 稳定 id,如 "codex" / "claude"
    var displayName: String     // "Codex" / "Claude"
    var aliases: [String]       // @ 触发别名(自动并入 displayName/id)
    var executable: String      // 可执行路径或命令名(如 /Applications/Codex.app/Contents/Resources/codex)
    var argsTemplate: [String]  // 参数模板,用 {{objective}} 占位(如 ["exec","{{objective}}"] 或 ["-p","{{objective}}"])
    var role: Role              // 在编排里默认承担的角色
    var subtitle: String        // 插件库/「+」菜单里的一句说明
    var icon: String            // SF Symbol
    var timeoutSeconds: Int     // 单次执行软超时
    // **持久可用状态**(2026-06-26):注册时探活、用时发现不可用都回写到这里。
    // optional 是为了向后兼容旧 JSON(缺这些键时解码为 nil = 视为可用)。
    var available: Bool?        // false=探活失败/用时发现不可用(登录失效/认证);nil 或 true=可用
    var unavailableReason: String?  // 不可用原因(登录失效/缺凭据…),给主人看 + UI 标注
    var lastCheckedAt: Date?   // 上次探活/状态更新时间

    enum Role: String, Codable, Sendable { case maker, checker, general }

    init(id: String, displayName: String, aliases: [String] = [], executable: String,
         argsTemplate: [String], role: Role = .general, subtitle: String = "", icon: String = "cpu",
         timeoutSeconds: Int = 600, available: Bool? = nil, unavailableReason: String? = nil,
         lastCheckedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.executable = executable
        self.argsTemplate = argsTemplate
        self.role = role
        self.subtitle = subtitle
        self.icon = icon
        self.timeoutSeconds = timeoutSeconds
        self.available = available
        self.unavailableReason = unavailableReason
        self.lastCheckedAt = lastCheckedAt
    }

    /// 全部可匹配别名(去重,含 displayName/id)。
    var allAliases: [String] {
        var seen = Set<String>()
        return ([displayName, id] + aliases)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 把 {{objective}} 填进参数模板,得到真实调用参数。
    func resolvedArguments(objective: String) -> [String] {
        argsTemplate.map { $0.replacingOccurrences(of: "{{objective}}", with: objective) }
    }

    /// 该 agent 当前是否真可用:① 没被标记为不可用(`available != false`,即没在探活/使用时发现登录失效等)
    /// ② 且可执行文件在。注册时探活、用前再核;登录失效这类「文件在但用不了」由持久状态 `available` 兜住。
    var isAvailableNow: Bool {
        guard available != false else { return false }   // 已被标记不可用(登录失效/缺凭据)→ 不可用,别再 @ 它/派活
        return FileManager.default.isExecutableFile(atPath: executable)
            || LingShuAgentPlugin.resolveInPath(executable) != nil
    }

    /// 可执行文件是否在(不看登录状态)——探活/恢复可用时用(文件在才值得重新探活)。
    var executableExists: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
            || LingShuAgentPlugin.resolveInPath(executable) != nil
    }

    /// 命令名在 PATH 里解析成绝对路径(executable 给的是命令名而非全路径时)。
    static func resolveInPath(_ command: String) -> String? {
        guard !command.contains("/") else { return nil }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
            .split(separator: ":").map(String.init)
        for p in paths {
            let full = (p as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}
