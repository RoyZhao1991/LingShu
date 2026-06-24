import Foundation

/// 完全版 #6 接线·**能力注册表进运行路径**:把灵枢可调度的各能力源(已连 MCP 工具 / 固化技能 等)
/// 包成统一 `LingShuCapabilityProvider`,经 `LingShuCapabilityRegistry.merge` 汇总成一份去重能力清单,
/// 通过只读工具 `list_capabilities` 摆到大脑眼前("我现在都能干什么 / 有没有现成能力做 X")。
/// 取向同 `LingShuCapabilityProvider` 注释:**只做统一枚举让大脑自己选,不做假精度的自动路由**。
/// 加新能力源 = 多包一个 provider,调度主流程不变。
struct LingShuStaticCapabilityProvider: LingShuCapabilityProvider {
    let caps: [LingShuCapability]
    init(_ caps: [LingShuCapability]) { self.caps = caps }
    func capabilities() -> [LingShuCapability] { caps }
}

@MainActor
extension LingShuState {

    /// P2·**能力快照**(给 GapAnalyzer 评估"能不能做成"用):核心原语 + 具身 + 知识 + 编排 + 已连 MCP/固化技能。
    /// 自我扩展元能力(author_component/discover_*/acquire_resource)由 GapAnalyzer 提示固定带,不在此重复。
    func capabilitySnapshot() -> String {
        var lines = [
            "- 核心原语:读/写/改文件、跑命令(run_command,可装依赖/编译/跑测试)、联网取页(fetch_url)、联网搜索(web_search)、全文搜索(search_text)、多文件补丁(apply_patch)",
            "- 计算机操作(授权后):看屏/列UI/点击/输入/滚动;内置多 tab 浏览器自动化(开页/导航/执行JS读DOM/读全文/截图)",
            "- 语音与演示:出声说(speak)、PPT/PDF/HTML 预览放映(open_preview)",
            "- 本机知识(全本地零上传):索引+语义检索本地文件/文档/代码/邮件/日历/照片(recall_local/index_*);长期记忆(recall_memory)",
            "- 外设/家电:列举与控制(peripherals/peripheral_control)",
            "- 编排:并行子任务(spawn_task)、命名角色团队(spawn_team,DAG 依赖)、定时(schedule_task)、后台守候(watch_until)"
        ]
        let caps = enumerateCapabilities()
        let bySource = Dictionary(grouping: caps, by: \.source)
        if let mcp = bySource["mcp"], !mcp.isEmpty {
            lines.append("- 已连 MCP 工具:" + mcp.prefix(24).map(\.description).joined(separator: "、"))
        }
        if let skills = bySource["skill"], !skills.isEmpty {
            lines.append("- 固化技能:" + skills.map(\.description).joined(separator: "、"))
        }
        // P2 真闭环:已获取并最小验证通过的能力 → 进快照供**复用**(同类目标不必重新获取)。
        let reusable = acquiredCapabilitiesContext()
        if !reusable.isEmpty { lines.append(reusable) }
        lines.append(capabilityNodeSnapshot(limit: 20))
        return lines.joined(separator: "\n")
    }

    /// 汇总当前可调度的扩展能力(MCP 连接器工具 + 固化技能)。纯枚举,无副作用。
    func enumerateCapabilities() -> [LingShuCapability] {
        var providers: [any LingShuCapabilityProvider] = []
        // ① 已连接的外部 MCP/连接器工具。
        let mcp = connectorRegistry.discoveredTools.map {
            LingShuCapability(id: "mcp:\($0.serverID).\($0.name)",
                              description: "\($0.serverName) / \($0.name):\($0.description.prefix(80))",
                              source: "mcp")
        }
        providers.append(LingShuStaticCapabilityProvider(mcp))
        // ② 固化(策展)技能——纯提示能力,apply_skill 引入。
        let skills = LingShuCuratedSkillRegistry.skills.map {
            LingShuCapability(id: "skill:\($0.domain)", description: "固化技能·\($0.domain)", source: "skill")
        }
        providers.append(LingShuStaticCapabilityProvider(skills))
        return LingShuCapabilityRegistry.merge(providers)
    }

    /// list_capabilities:把统一能力清单(按来源归类)摆给大脑。只读、无副作用,所有会话可用。
    func listCapabilitiesTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "list_capabilities",
            description: "列出当前能力节点:内核能力、MCP/技能、已获取能力、模型、语音视觉、外部 agent 等,包含状态、风险、权限和是否可调度。用于自检『我现在都能干什么』或判断『有没有现成能力做 X,不必从零造』。返回只读清单,不执行任何动作。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{},\"required\":[]}"
        ) { [weak self] _ in
            let nodes = await MainActor.run { [weak self] in self?.capabilityNodes() ?? [] }
            guard !nodes.isEmpty else {
                return "当前没有注册的能力节点。"
            }
            let ready = nodes.filter(\.isSchedulable).count
            let grouped = Dictionary(grouping: nodes, by: \.kind)
            var lines: [String] = ["当前能力节点共 \(nodes.count) 项,可调度 \(ready) 项,待补齐 \(nodes.count - ready) 项:"]
            for kind in LingShuCapabilityNodeKind.allCases {
                guard let items = grouped[kind], !items.isEmpty else { continue }
                lines.append("【\(kind.rawValue)】")
                for node in items {
                    let state = node.isSchedulable ? "可调度" : node.status.rawValue
                    lines.append("  · \(node.name) [\(state), risk=\(node.risk.rawValue), permission=\(node.permissionSummary)]")
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}
