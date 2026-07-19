import Foundation

/// 权限作用域检查器(P1 的"执法"原语,纯逻辑可单测):某动作是否落在插件声明的范围内、声明有多宽(风险评级)、
/// 一组请求里有哪些越权。P2(动态工具)/P3(沙箱)都基于它做拦截。
enum LingShuPluginPermissionChecker {
    enum RiskLevel: String, Sendable, Comparable {
        case low, medium, high
        private var rank: Int { self == .low ? 0 : (self == .medium ? 1 : 2) }
        static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rank < b.rank }
    }

    static func allowsRead(_ m: LingShuPluginManifest, path: String) -> Bool {
        matchesAny(m.permissions.fileRead, path) || matchesAny(m.permissions.fileWrite, path)
    }
    static func allowsWrite(_ m: LingShuPluginManifest, path: String) -> Bool {
        matchesAny(m.permissions.fileWrite, path)
    }
    static func allowsNetwork(_ m: LingShuPluginManifest, host: String) -> Bool {
        let h = host.lowercased()
        return m.permissions.network.contains("*") || m.permissions.network.contains { hostMatches(pattern: $0.lowercased(), host: h) }
    }

    /// 声明的权限有多宽 → 审批醒目程度。系统敏感=高;跑命令且(任意联网或任意写)=高;三者任一=中;否则低。
    static func riskLevel(_ m: LingShuPluginManifest) -> RiskLevel {
        let p = m.permissions
        if p.systemSensitive { return .high }
        let anyNet = p.network.contains("*")
        let anyWrite = p.fileWrite.contains("*")
        if p.shell && (anyNet || anyWrite) { return .high }
        if p.shell || anyNet || anyWrite { return .medium }
        return .low
    }

    /// 越权检测:请求的写/联网/跑命令里有哪些超出声明范围(供运行期拦截 / 触发再审批)。
    static func violations(of m: LingShuPluginManifest, writes: [String] = [], hosts: [String] = [], shell: Bool = false) -> [String] {
        var out: [String] = []
        for w in writes where !allowsWrite(m, path: w) { out.append("写越权:\(w)") }
        for h in hosts where !allowsNetwork(m, host: h) { out.append("联网越权:\(h)") }
        if shell && !m.permissions.shell { out.append("未声明 shell 却要跑命令") }
        return out
    }

    // MARK: - 匹配(纯)

    private static func matchesAny(_ patterns: [String], _ path: String) -> Bool {
        guard !patterns.isEmpty else { return false }
        let p = expandTilde(path)
        return patterns.contains { pattern in
            let pat = expandTilde(pattern)
            if pat.contains("*") { return globMatch(pattern: pat, path: p) }
            // 无通配:精确 或 目录前缀(声明一个目录即覆盖其下)
            return p == pat || p.hasPrefix(pat.hasSuffix("/") ? pat : pat + "/")
        }
    }

    private static func expandTilde(_ s: String) -> String {
        s.hasPrefix("~") ? LingShuRuntimeEnvironment.homeDirectory.path + s.dropFirst().description : s
    }

    /// 简易 glob → 正则:`**` 匹配任意(含 /),`*` 匹配除 / 外任意;其余字符转义。
    static func globMatch(pattern: String, path: String) -> Bool {
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex, pattern[next] == "*" {
                    regex += ".*"; i = pattern.index(after: next); continue
                }
                regex += "[^/]*"
            } else if "\\^$.|?+()[]{}".contains(c) {
                regex += "\\" + String(c)
            } else {
                regex += String(c)
            }
            i = pattern.index(after: i)
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }

    /// 域名匹配:`*.example.com` 匹配子域;`example.com` 匹配自身或其子域。
    static func hostMatches(pattern: String, host: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(1))   // ".example.com"
            return host.hasSuffix(suffix) || host == String(pattern.dropFirst(2))
        }
        return host == pattern || host.hasSuffix("." + pattern)
    }
}
