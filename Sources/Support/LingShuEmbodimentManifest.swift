import Foundation

/// **超越点·灵枢当 MCP server**:把灵枢独有的"具身能力"(计算机直接操作 / 内置浏览器自动化 / 语音 / 外设家电)
/// 通过既有 8917 MCP server(`LingShuControlServer` + `LingShuControlRouter`,标准 JSON-RPC initialize/tools/list/tools/call)
/// 暴露给**外部 agent**(Claude Code / Codex / Cursor 等)反向调用 = **给只有终端的 agent 装上一副身体**。
/// 这是 CC/Codex 给不了的独家维度:灵枢既是最富的 MCP 客户端,又是别人造不出的 MCP 服务端。
///
/// 通用零定制:暴露集是**通用具身能力层**(按能力分组,非任务/领域特判)。安全:工具 handler 仍走各自的系统授权门
/// (计算机控制需 AX/录屏授权等)——红线不放松;且 8917 仅本机可达、本就有 `lingshu_send_prompt`(可驱动全能力),
/// 故暴露具身工具不新增攻击面(同一本地信任边界)。可替换/可关:开关 `lingshu.exposeEmbodiment`(默认开)。
enum LingShuEmbodimentManifest {

    /// 对外暴露的具身能力工具名(通用 body 层:计算机控制 + 浏览器自动化 + 语音 + 外设)。
    static let exposedToolNames: Set<String> = [
        // 计算机直接操作(看屏 + 鼠标键盘)
        "screen_capture", "list_ui_elements", "click", "double_click", "move_mouse", "type_text", "press_key", "scroll",
        // 内置浏览器自动化(开页/导航/多 tab/执行 JS 读 DOM/读全文/滚动/全屏/关)
        "browser_open", "browser_navigate", "browser_tab", "browser_eval", "browser_read", "browser_scroll", "browser_fullscreen", "browser_close",
        // 语音(嘴:主动 TTS 念出)
        "speak",
        // 外设 / 家电(列举 + 标注控制)
        "peripherals", "label_peripheral",
    ]

    /// 是否对外暴露具身工具(默认开;`lingshu.exposeEmbodiment` 可关)。
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "lingshu.exposeEmbodiment") as? Bool) ?? true
    }

    /// 从全量 agent 工具里过滤出可对外暴露的具身工具(纯逻辑)。关则空。
    static func filter(_ tools: [LingShuAgentTool]) -> [LingShuAgentTool] {
        guard isEnabled else { return [] }
        return tools.filter { exposedToolNames.contains($0.name) }
    }

    /// 转成 MCP tool 描述符(tools/list 用):name + description(带[灵枢具身]前缀)+ inputSchema(从 parametersJSON 解析)。纯逻辑。
    static func descriptors(from tools: [LingShuAgentTool]) -> [[String: Any]] {
        filter(tools).map { tool in
            let schema = tool.parametersJSON.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? ["type": "object", "properties": [:] as [String: Any]]
            return [
                "name": tool.name,
                "description": "[灵枢具身] " + tool.description,
                "inputSchema": schema
            ]
        }
    }

    /// 在给定工具集中按名找一个已暴露的具身工具(tools/call 派发用)。关或非具身 → nil。
    static func tool(named name: String, in tools: [LingShuAgentTool]) -> LingShuAgentTool? {
        guard isEnabled, exposedToolNames.contains(name) else { return nil }
        return tools.first { $0.name == name }
    }
}
