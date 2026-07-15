import Foundation

/// 差距7-B·**工具目录可替换模块**(schema 延迟加载,治"64 工具全量注入→强脑也慢")。
///
/// 设计取向(协议风格 + 单一切换点 + 按脑力 gate,用户拍板"按脑力自适应"):
/// **所有工具的 handler 始终注册可执行**(不丢能力),只是**给模型的 schema** 收成「高频核心集 + `search_tools` 元工具」;
/// 模型需要核心集外的专用能力时先 `search_tools(query)` → 按相关性返回匹配工具的用法**并激活**它们 → 之后可直接调用。
/// 这是 CC 的 ToolSearch 模式(已验证):活跃 schema 小 → preamble 瘦 → 延迟降。**核心/延迟的划分是通用频率层级**
/// (基础原语 + 高频工具),非任务/领域特判,符合通用零定制。
///
/// 动态激活靠**引用型 `LingShuExposedToolSet`**(锁保护):search_tools 的 handler 往里加名字,核心循环每回合读它
/// 决定喂给模型的活跃集 → 下一回合即见新工具。core 循环只多"算活跃集"一行,不做 per-工具特判。

/// 当前向模型暴露(可被调用)的工具名集合。引用类型:核心循环读、search_tools handler 写,锁保护跨并发安全。
final class LingShuExposedToolSet: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String>
    init(initial: Set<String>) { names = initial }
    func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
    func add(_ newNames: [String]) { lock.lock(); names.formUnion(newNames); lock.unlock() }
    func snapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return names }
}

/// 工具相关性排序(纯逻辑,可单测):按 query 词在工具名(权重高)/描述(权重低)的命中给分,降序取前 limit。
enum LingShuToolRelevance {
    static func rank(query: String, tools: [LingShuAgentTool], limit: Int) -> [LingShuAgentTool] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }
        let scored: [(LingShuAgentTool, Int)] = tools.map { tool in
            let name = tool.name.lowercased()
            let desc = tool.description.lowercased()
            var score = 0
            for t in tokens {
                if name.contains(t) { score += 3 }
                if desc.contains(t) { score += 1 }
            }
            return (tool, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    /// 英文按非字母数字切词;CJK 单字成 token(短关键词场景够用,字级子串匹配)。
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { tokens.append(cur); cur = "" } }
        for ch in s.lowercased() {
            if let scalar = ch.unicodeScalars.first, scalar.value >= 0x3400 {
                flush(); tokens.append(String(ch))         // CJK 等:单字成 token
            } else if ch.isLetter || ch.isNumber {
                cur.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}

/// 延迟目录构建器:核心集恒暴露 + `search_tools` 元工具按需激活长尾工具。
enum LingShuToolCatalog {
    /// **通用高频/原语层**(非任务特判):这些恒暴露。其余工具延迟到 search_tools 激活。
    /// 注:`recall_local` = 本机知识检索,用户定调为**基础能力、对话里永远可用**,故必须在核心集——
    /// 即便强脑走延迟加载也绝不藏到 search_tools 后(否则"涉及本机资料先 recall_local"的对话引导会落空)。
    static let coreToolNames: Set<String> = [
        "read_file", "write_file", "edit_file", "apply_patch", "run_command",
        "start_long_command", "check_long_command", "cancel_long_command", "list_long_commands",
        "web_search",
        "ask_user", "ask_form", "speak", "recall_memory", "recall_local", "update_plan", "spawn_task",
        "computer_list_apps", "computer_get_state", "computer_click_element", "computer_set_text",
        "computer_press_key", "computer_scroll_element", "computer_drag_element", "computer_perform_action",
        "present_documents",   // 「演示与答疑」插件:恒可见,做正式文档演示时大脑直接用
        "self_inspect"   // 自检:随时拉自己的整体架构+实时能力(答自指/规划/自进化用真实自我认知)
    ]
    static let searchToolName = "search_tools"

    /// 构建延迟目录:返回(全量 handler 列表 + search_tools, 初始暴露集=核心∪search_tools)。
    /// search_tools handler 捕获长尾工具,按 query 排序、激活并回报用法。
    static func build(allTools: [LingShuAgentTool], coreNames: Set<String> = coreToolNames)
        -> (tools: [LingShuAgentTool], exposed: LingShuExposedToolSet) {
        let presentCore = Set(allTools.map(\.name)).intersection(coreNames)
        let deferredTools = allTools.filter { !coreNames.contains($0.name) }
        let holder = LingShuExposedToolSet(initial: presentCore.union([searchToolName]))

        let searchTool = LingShuAgentTool(
            name: searchToolName,
            description: "按能力关键词查找并**激活**当前未直接列出的专用工具(如浏览器/截屏点击/演示放映/会议/定时/外设家电/自造工具等)。需要核心工具(读写改/run_command/web_search/ask 等)之外的能力时,先调它:它会返回匹配工具的用法**并激活**,之后即可直接调用那些工具。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"要找的能力关键词,如 浏览器/截屏/演示/会议/定时/家电/数字人\"}},\"required\":[\"query\"]}"
        ) { argsJSON in
            let query = Self.extractQuery(argsJSON)
            let matched = LingShuToolRelevance.rank(query: query, tools: deferredTools, limit: 8)
            guard !matched.isEmpty else {
                let names = deferredTools.map(\.name).joined(separator: ", ")
                return "没找到匹配「\(query)」的专用工具。当前可按需激活的有:\(names)。换个关键词再试,或直接用核心工具完成。"
            }
            holder.add(matched.map(\.name))
            let lines = matched.map { "- \($0.name):\($0.description)\n  参数schema:\($0.parametersJSON)" }.joined(separator: "\n")
            return "已激活以下工具,现在可直接调用:\n\(lines)"
        }
        return (allTools + [searchTool], holder)
    }

    static func extractQuery(_ argsJSON: String) -> String {
        guard let data = argsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (obj["query"] as? String) ?? ""
    }
}
