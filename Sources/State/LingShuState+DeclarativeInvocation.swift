import Foundation

/// **声明式调插件**接进 LingShuState:可调插件注册表 + 路由(`@演示`/`用录制技能`/「+」菜单 pinned → 确定性直达)。
/// 这是对反复出现的「大脑误调用/绕开新插件」的系统性修复——用户一旦显式声明,就不再交给大脑判断。
@MainActor
extension LingShuState {

    /// 当前**可被声明式调用**的插件/能力清单(给「+」菜单展示 + 文本前缀匹配)。
    /// 按可用性实时过滤(如录制要计算机控制授权;演示总在)。
    func invocablePlugins() -> [LingShuInvocablePlugin] {
        var list: [LingShuInvocablePlugin] = []
        // **已注册的 agent 插件**(被告知可用→注册进插件库,零硬编码;不再写死 codex/claude)。可执行文件在才出现。
        for a in LingShuAgentPluginStore.load() where a.isAvailableNow {
            list.append(.init(id: "agent:\(a.id)", displayName: a.displayName, aliases: a.aliases,
                              subtitle: a.subtitle.isEmpty ? "已注册 agent(\(a.role.rawValue))" : a.subtitle,
                              icon: a.icon, kind: .agent))
        }
        // **插件**
        list.append(contentsOf: [
            .init(id: "present", displayName: "演示与答疑",
                  aliases: ["演示", "讲解", "present", "放映"],
                  subtitle: "把文档/网页正式演示讲解,边讲边答疑", icon: "play.rectangle.on.rectangle"),
            .init(id: "record", displayName: "录制技能",
                  aliases: ["录制", "记录技能", "学技能", "record"],
                  subtitle: "看你做一遍→学成可复用技能,以后一句话带新参数 replay", icon: "record.circle"),
        ])
        // 已学会的过程技能,每个也可直接声明调用(用 X 技能)。
        for s in LingShuProcedureSkillRouter.loadProcedures().prefix(8) {
            list.append(.init(id: "proc:\(s.id)", displayName: s.title,
                              aliases: s.triggers, subtitle: "已学会的技能" + (s.parameters.isEmpty ? "" : "(参数:\(s.parameters.map(\.name).joined(separator: "、")))"),
                              icon: "wand.and.stars"))
        }
        return list
    }

    /// 文本声明(`@Codex 开发X @Claude 验收`/`@演示 …`)或「+」菜单 pinned(可多选)→ 确定性路由。返回 true=已接管。
    func handleDeclarativeInvocationIfNeeded(_ prompt: String) -> Bool {
        let plugins = invocablePlugins()
        // 文本 `@链式`(@Codex 开发X @Claude 验收Y)——「+」菜单选中即往输入框插 @名字,inline 编排,提交时按序解析成链。
        let chain = LingShuDeclarativeInvocation.detectChain(prompt, plugins: plugins)
        lingShuControlLog("声明式链解析: 输入「\(prompt.prefix(30))」可调=\(plugins.map(\.id)) → 链=\(chain.map { "\($0.id)::\($0.segment.prefix(14))" })")
        if !chain.isEmpty {
            chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
            appendTrace(kind: .route, actor: "声明式调用", title: "用户显式指定",
                        detail: "链:\(chain.map { $0.id }.joined(separator: " → "))(跳过大脑分诊)")
            runInvocationChain(chain.map { (id: $0.id, segment: $0.segment) }, plugins: plugins)
            return true
        }
        // ③ 单个 `用X插件`/`切到X` 声明。
        if let hit = LingShuDeclarativeInvocation.detect(prompt, plugins: plugins) {
            chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
            runInvocationChain([(id: hit.id, segment: hit.rest)], plugins: plugins)
            return true
        }
        return false
    }


    /// 顺序执行声明链:agent 步走真委托(后一个 agent 拿到前一步产出→天然 maker≠checker);插件步路由各自插件。
    private func runInvocationChain(_ steps: [(id: String, segment: String)], plugins: [LingShuInvocablePlugin]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var priorOutput = ""
            for step in steps {
                guard let inv = plugins.first(where: { $0.id == step.id }) else { continue }
                switch inv.kind {
                case .agent:
                    // 从插件库取这个**已注册 agent**,统一用 Store.run 跑(零硬编码,任何 CLI agent 同一套)。
                    let agentID = inv.id.hasPrefix("agent:") ? String(inv.id.dropFirst("agent:".count)) : inv.id
                    guard let plugin = LingShuAgentPluginStore.plugin(id: agentID) else {
                        self.speakAndChat("agent「\(inv.displayName)」没注册或不可用,跳过。"); continue
                    }
                    let obj = step.segment + (priorOutput.isEmpty ? "" : "\n\n【上一步产出,供你参考/复核】\n" + String(priorOutput.prefix(4000)))
                    self.speakAndChat("交给 \(plugin.displayName):\(step.segment.prefix(50))")
                    let result = await LingShuAgentPluginStore.run(plugin, objective: obj, workingDirectory: self.codexWorkingDirectory)
                    let out: String
                    switch result {
                    case .completed(let t): out = t
                    case .failure(let r):   out = "（\(plugin.displayName) 未完成:\(r)）"
                    }
                    self.chatMessages.append(.init(speaker: "灵枢", text: "【\(plugin.displayName)】\n\(out)", isUser: false))
                    priorOutput = out
                case .plugin:
                    self.routePlugin(pluginID: inv.id, rest: step.segment)
                }
            }
        }
    }

    /// 把(已确认的)输入路由给指定**插件**(present/record/proc)。
    private func routePlugin(pluginID: String, rest: String) {
        switch pluginID {
        case "present":
            let paths = Self.extractExistingFilePaths(rest)
            guard !paths.isEmpty else {
                speakAndChat("好,用演示插件——把要演示的文档路径发我(比如 /Users/.../方案.pdf),我就开讲。")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = await self.startPresentation(paths: paths)
                self.chatMessages.append(.init(speaker: "灵枢", text: msg, isUser: false))
            }
        case "record":
            startProcedureRecording(name: rest.isEmpty ? nil : rest)
        default:
            // proc:<id> —— 直接 replay 这个已学会的技能(rest 里带参数)。
            if pluginID.hasPrefix("proc:") {
                let sid = String(pluginID.dropFirst("proc:".count))
                let skills = LingShuProcedureSkillRouter.loadProcedures()
                if let skill = skills.first(where: { $0.id == sid }) {
                    if let gate = computerControlGate(requiresAccessibility: true) { speakAndChat("要跑这个技能我得能操作界面。\(gate)"); return }
                    let params = LingShuProcedureSkillRouter.extractParams(rest, for: skill)
                    let missing = skill.missingParameters(given: params)
                    if !missing.isEmpty {
                        let hints = skill.parameters.filter { missing.contains($0.name) }.map { $0.example.isEmpty ? $0.name : "\($0.name)(如\($0.example))" }.joined(separator: "、")
                        speakAndChat("用「\(skill.title)」还差参数:\(hints)。一次说全我就跑。")
                    } else {
                        replayProcedure(skill: skill, params: params)
                    }
                    return
                }
            }
            speakAndChat("我不认识这个插件:\(pluginID)。")
        }
    }

    /// 从文本里抽**真实存在的**文件路径(声明式已表意图,不再要求意图词)。
    nonisolated static func extractExistingFilePaths(_ text: String) -> [String] {
        let exts = ["pdf", "pptx", "ppt", "docx", "doc", "key", "html", "htm", "md", "txt", "xlsx"]
        let pattern = "(/[^\\s,，；;、]+\\.(?:" + exts.joined(separator: "|") + "))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var paths: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m { paths.append(ns.substring(with: m.range)) }
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
