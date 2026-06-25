import Foundation

/// 一等公民「按内容搜代码」四肢(补齐对标 Claude Code 的 Grep / Codex 的 ripgrep)。
/// 之前灵枢只能 `run_command` 手拼 grep——大代码库里慢且易错。这里给一个带好默认(递归/行号/排除构建目录/
/// 结果上限)的结构化搜索工具:有 ripgrep 用 rg(快),否则回退系统 grep,**通用零依赖**。
@MainActor
extension LingShuState {

    func searchTextTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "search_text",
            description: "在代码库里按内容快速搜索(正则),返回 文件:行号:匹配行。比手写 run_command grep 更快更准:递归、自动排除 .git/构建产物、结果有上限。定位符号/用法/字符串时优先用它。",
            parametersJSON: """
            {"type":"object","properties":{
            "pattern":{"type":"string","description":"要搜的正则/字符串"},
            "path":{"type":"string","description":"(可选)搜索根目录,默认当前工作目录"},
            "glob":{"type":"string","description":"(可选)只搜匹配此通配的文件名,如 *.swift"},
            "max_results":{"type":"number","description":"(可选)最多返回多少行,默认 80"}
            },"required":["pattern"]}
            """
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            let pattern = (Self.jsonField(argsJSON, "pattern") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { return "缺少 pattern。" }
            let root = await MainActor.run { Self.jsonField(argsJSON, "path")?.nonEmptyOrNilSearch ?? self.agentWorkingDirectory }
            let glob = Self.jsonField(argsJSON, "glob")?.nonEmptyOrNilSearch
            let cap = Int(Self.jsonNumber(argsJSON, "max_results") ?? 80)
            return await Self.runSearch(pattern: pattern, root: root, glob: glob, cap: max(1, cap))
        }
    }

    /// 跑搜索:优先 ripgrep,回退系统 grep。截到 cap 行,附命中数提示。
    nonisolated static func runSearch(pattern: String, root: String, glob: String?, cap: Int) async -> String {
        let rgPaths = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
        let raw: String
        if let rg = rgPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            var args = ["--line-number", "--no-heading", "--color", "never", "--max-count", "50",
                        "-g", "!.git", "-g", "!.build", "-g", "!dist", "-g", "!*.xcodeproj"]
            if let glob { args += ["-g", glob] }
            args += [pattern, root]
            raw = await runReadCommand(rg, args, timeout: 20)
        } else {
            // 系统 grep 兜底:递归 + 行号 + 排除常见目录。
            var args = ["-rnI", "--exclude-dir=.git", "--exclude-dir=.build", "--exclude-dir=dist"]
            if let glob { args += ["--include", glob] }
            args += ["-e", pattern, root]
            raw = await runReadCommand("/usr/bin/grep", args, timeout: 20)
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return "未找到「\(pattern)」的匹配(根目录:\(root)\(glob.map { " · " + $0 } ?? ""))。" }
        let shown = lines.prefix(cap)
        let more = lines.count > cap ? "\n…（共 \(lines.count) 行命中,已截断到 \(cap);缩小范围或加 glob 精确定位）" : ""
        return "「\(pattern)」命中 \(lines.count) 行:\n" + shown.joined(separator: "\n") + more
    }
}

private extension String {
    var nonEmptyOrNilSearch: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
