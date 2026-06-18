import Foundation

/// 插件/技能的**声明式权限作用域**(P1)。扩展必须**声明它需要碰什么**(读写哪些路径、联哪些域名、要不要跑命令),
/// 系统据此做最小权限审批与越权检测。纯值类型,可单测。
/// 注:P1 是**声明 + 审批作用域**层;OS 级强制隔离(sandbox)是 P3。
struct LingShuPluginPermissions: Equatable, Sendable {
    var fileRead: [String] = []      // 允许读的路径/glob(支持 ~、*、**)
    var fileWrite: [String] = []     // 允许写的路径/glob
    var network: [String] = []       // 允许联的域名;"*" = 任意
    var shell: Bool = false          // 是否需要跑命令(run_command)
    var systemSensitive: Bool = false// 是否触及系统敏感(/System、/etc…;应极少且高审批)

    var isEmpty: Bool {
        fileRead.isEmpty && fileWrite.isEmpty && network.isEmpty && !shell && !systemSensitive
    }
}

/// 插件清单:身份 + 提供的工具 + 声明的权限。可从 skill 的 frontmatter 解析(向后兼容:没声明=最小权限)。
struct LingShuPluginManifest: Equatable, Sendable {
    enum Source: String, Sendable { case builtin, curated, user, discovered, unknown }

    var id: String
    var name: String
    var version: String
    var providedTools: [String]      // 声明提供/使用的工具名(P2 动态注册据此)
    var permissions: LingShuPluginPermissions
    var source: Source

    /// 从 skill frontmatter 解析。约定键(全可选,缺省=最小权限):
    ///  `perm_read` / `perm_write`:逗号分隔路径/glob;`perm_network`:逗号分隔域名(* = 任意);
    ///  `perm_shell`:true/false;`perm_system`:true/false;`provides`:逗号分隔工具名;`version`。
    static func from(frontmatter: [String: String], source: Source) -> LingShuPluginManifest {
        func list(_ key: String) -> [String] {
            (frontmatter[key] ?? "")
                .split(whereSeparator: { ",，、".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        func flag(_ key: String) -> Bool { (frontmatter[key] ?? "false").trimmingCharacters(in: .whitespaces).lowercased() == "true" }
        func value(_ key: String) -> String? {
            let v = frontmatter[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty == false) ? v : nil
        }

        let permissions = LingShuPluginPermissions(
            fileRead: list("perm_read"),
            fileWrite: list("perm_write"),
            network: list("perm_network"),
            shell: flag("perm_shell"),
            systemSensitive: flag("perm_system")
        )
        return LingShuPluginManifest(
            id: value("id") ?? value("title") ?? "plugin",
            name: value("title") ?? value("id") ?? "未命名插件",
            version: value("version") ?? "1.0",
            providedTools: list("provides"),
            permissions: permissions,
            source: source
        )
    }

    /// 人可读的权限摘要(供审批/apply_skill 展示)。
    var permissionSummary: String {
        if permissions.isEmpty { return "无特殊权限声明(最小权限)" }
        var parts: [String] = []
        if !permissions.fileRead.isEmpty { parts.append("读:\(permissions.fileRead.joined(separator: "、"))") }
        if !permissions.fileWrite.isEmpty { parts.append("写:\(permissions.fileWrite.joined(separator: "、"))") }
        if !permissions.network.isEmpty { parts.append("联网:\(permissions.network.joined(separator: "、"))") }
        if permissions.shell { parts.append("跑命令") }
        if permissions.systemSensitive { parts.append("系统敏感") }
        return parts.joined(separator: " | ")
    }
}
