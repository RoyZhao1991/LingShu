import Foundation

/// P3 插件脚本沙箱:从插件声明的权限(P1)生成 macOS `sandbox-exec` 的 SBPL 配置,把未审/第三方脚本
/// **关进受限子进程**——默认拒绝,只放行声明的写路径与(粗粒度)网络;读放宽(解释器/系统库需要)。
/// 配置生成是**纯逻辑可单测**;真正 confine 由 `sandbox-exec` 执行(调用方用 `wrap`)。
/// 诚实边界:SBPL **难按域名限网**——网络是"声明了就整体放、没声明就断";域名级限制留在 app/runner 层(P1 checker)。
enum LingShuPluginSandbox {

    /// 由权限生成 SBPL 配置文本。
    static func profile(for permissions: LingShuPluginPermissions) -> String {
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(allow process-fork)",
            "(allow process-exec)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow file-read*)"          // 读放宽:跑解释器/加载库/读输入都要
        ]
        if permissions.fileWrite.contains("*") {
            lines.append("(allow file-write*)")
        } else {
            for path in permissions.fileWrite {
                lines.append("(allow file-write* (subpath \"\(expand(path))\"))")
            }
            // 临时目录通常必需(脚本中间产物)
            lines.append("(allow file-write* (subpath \"/private/tmp\"))")
            lines.append("(allow file-write* (subpath \"/private/var/folders\"))")
        }
        if !permissions.network.isEmpty {
            lines.append("(allow network*)")   // 声明了就放网络(域名级在 runner 层另限)
        }
        return lines.joined(separator: "\n")
    }

    /// 把一条命令包成 `sandbox-exec -p <profile> <exec> <args...>`,在声明的最小权限下运行。
    static func wrapped(executable: String, arguments: [String], permissions: LingShuPluginPermissions)
        -> (executable: String, arguments: [String]) {
        let prof = profile(for: permissions)
        return ("/usr/bin/sandbox-exec", ["-p", prof, executable] + arguments)
    }

    /// 沙箱是否真正可用(/usr/bin/sandbox-exec 存在)。不可用时调用方应退回"声明+审批"而非裸跑。
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst().description
            : path
    }
}
