import Foundation

/// 任务窗口消息格式化与净化——独立纯工具模块(不依赖 UI/State 实例):
/// 工具卡摘要、参数美化、录制净化(身份铁律 + 干净渲染)。供录制端与窗口复用,可单测。
enum LingShuTaskMessageFormatting {

    /// 录制净化:① 抹掉底层模型名(MiniMax/Qwen/通义千问/GPT/Claude…,身份铁律——窗口绝不暴露底层模型)
    /// ② 把"裸 assistant tool_calls JSON 转储"压成一句话(那种 `{"role":"assistant",...tool_calls...}` 不该进窗口)。
    static func sanitize(_ text: String) -> String {
        var out = text
        // ② 裸模型响应 JSON(含 tool_calls)→ 收敛成简短占位,别把整坨 JSON 灌进任务窗口。
        if out.contains("\"tool_calls\"") && (out.contains("\"role\"") || out.contains("\"function\"")) {
            out = "（已发起工具调用）"
        }
        // ① 模型名泄露 → 统一抹成"灵枢"(身份只有灵枢)。
        let leaks = ["MiniMax AI", "MiniMax", "minimax", "通义千问", "Qwen", "qwen", "GPT-4", "GPT", "ChatGPT", "Claude", "DeepSeek", "deepseek"]
        for leak in leaks { out = out.replacingOccurrences(of: leak, with: "灵枢") }
        return out
    }

    /// 工具调用的一句话摘要(卡片标题):命令/路径/查询直出,比裸参数 dict 可读得多。
    static func toolCallSummary(tool: String, arguments: [String: String]) -> String {
        switch tool {
        case "run_command":
            let cmd = (arguments["command"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
            return String(firstLine.prefix(160))
        case "write_file":   return "写入 \((arguments["path"] ?? "").trimmingCharacters(in: .whitespaces))"
        case "read_file":    return "读取 \((arguments["path"] ?? "").trimmingCharacters(in: .whitespaces))"
        case "list_directory": return "列目录 \((arguments["path"] ?? ".").trimmingCharacters(in: .whitespaces))"
        case "fetch_url":    return "抓取 \((arguments["url"] ?? "").trimmingCharacters(in: .whitespaces))"
        case "web_search":   return "搜索 \((arguments["query"] ?? arguments["q"] ?? "").trimmingCharacters(in: .whitespaces))"
        case "apply_skill":  return "调取技能 · \((arguments["task"] ?? "").trimmingCharacters(in: .whitespaces).prefix(60))"
        default:
            let mcp = tool.hasPrefix("mcp:") ? String(tool.dropFirst(4)) : tool
            let argText = prettyArguments(arguments)
            return argText.isEmpty || argText == "{}" ? mcp : "\(mcp) \(argText.prefix(120))"
        }
    }

    /// 完整参数美化成 JSON(卡片展开用)。MCP 信封先解包,展示真实参数。
    static func prettyArguments(_ arguments: [String: String]) -> String {
        let unwrapped = LingShuState.unwrapMCPArguments(arguments)
        guard let data = try? JSONSerialization.data(withJSONObject: unwrapped, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return arguments.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        }
        return text
    }
}
