import Foundation

/// 输入框里被声明式 `@` 到的 agent/插件芯片(驱动输入框上方"将编排"提示条)。
struct LingShuInvocationChip: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let role: String
    let isAgent: Bool

    static func == (a: LingShuInvocationChip, b: LingShuInvocationChip) -> Bool {
        a.name == b.name && a.role == b.role && a.isAgent == b.isAgent
    }
}

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

    /// 当前所有**可 @ 触发**的别名(displayName + aliases 去重)——供输入框内嵌 token 高亮判定。
    /// 读盘一次,调用方缓存(别每次按键调)。
    func invocableAliases() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in invocablePlugins() {
            for a in ([p.displayName] + p.aliases) {
                let t = a.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, seen.insert(t).inserted { out.append(t) }
            }
        }
        return out
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
    /// **同一编排任务=一个气泡换行追加**(不拆成多气泡);每步落 trace,运行时(状态/运维)能看清启动的是哪个 agent。
    private func runInvocationChain(_ steps: [(id: String, segment: String)], plugins: [LingShuInvocablePlugin]) {
        // 纯插件步(present/record/proc)不进 agent 气泡——它们各自有交互/窗口。
        let agentSteps = steps.filter { id in plugins.first(where: { $0.id == id.id })?.kind == .agent }
        for step in steps where plugins.first(where: { $0.id == step.id })?.kind == .plugin {
            routePlugin(pluginID: step.id, rest: step.segment)
        }
        guard !agentSteps.isEmpty else { return }

        // **用户定调 2026-06-25:声明式 @agent 是任务,必须走 LOOP——把 agent 作为 maker 引入循环(灵枢编排+验收),绝不绕过验收。**
        // maker = 第一个 @agent(其 segment=开发目标);checker = 第二个 @agent(如 @Claude 验收)或灵枢自己(maker≠checker 跨厂商)。
        func resolve(_ step: (id: String, segment: String)) -> (agentID: String, name: String)? {
            guard let inv = plugins.first(where: { $0.id == step.id }) else { return nil }
            let agentID = inv.id.hasPrefix("agent:") ? String(inv.id.dropFirst("agent:".count)) : inv.id
            guard LingShuAgentPluginStore.plugin(id: agentID) != nil else { return nil }
            return (agentID, inv.displayName)
        }
        guard let maker = resolve(agentSteps[0]) else {
            let nm = plugins.first(where: { $0.id == agentSteps[0].id })?.displayName ?? "agent"
            chatMessages.append(.init(speaker: "灵枢", text: "⚠️ @\(nm) 没注册或不可用——先告诉我本机有它、怎么调,我注册后再用。", isUser: false))
            return
        }
        let checker = agentSteps.count >= 2 ? resolve(agentSteps[1]) : nil
        let objective = agentSteps[0].segment.trimmingCharacters(in: .whitespacesAndNewlines)

        // 建任务记录 + GoalSpec(目标解析稳定)→ 走标准 LOOP(dispatchIsolatedTask),maker 换成 agent session。
        let displayObjective = objective.isEmpty ? "\(maker.name) 任务" : objective
        let rid = createTaskExecutionRecord(for: displayObjective)
        if goalSpecEnabled { bindGoalSpec(LingShuGoalSpec(objective: displayObjective, kind: .task), to: rid) }
        appendTrace(kind: .route, actor: "声明式调用", title: "@agent 进 LOOP",
                    detail: "maker=\(maker.name) · checker=\(checker?.name ?? "灵枢")(任何任务都走 LOOP,maker 换成 agent session,不绕过验收)")
        _ = dispatchIsolatedTask(prompt: objective, taskRecordID: rid, goal: objective.isEmpty ? nil : objective,
                                 makerAgentID: maker.agentID, makerName: maker.name,
                                 checkerAgentID: checker?.agentID, checkerName: checker?.name)
    }

    /// 编排气泡整段重写(单气泡承载:已定稿部分 + 运行中实时进度)。气泡没了(被清)就忽略。
    func renderChainBubble(_ bid: UUID, _ text: String) {
        guard let i = chatMessages.firstIndex(where: { $0.id == bid }) else { return }
        chatMessages[i].text = text
    }

    /// agent 输出是否表明「没写入权限 / 只读环境」(没真落地文件,只在对话里贴了内容=无效交付)。验收据此触发授权兜底。
    nonisolated static func agentOutputLacksPermission(_ text: String) -> Bool {
        let lower = text.lowercased()
        let en = ["read-only", "readonly", "permission denied", "cannot write", "operation not permitted",
                  "not permitted to write", "eacces", "erofs", "sandbox is read"]
        if en.contains(where: { lower.contains($0) }) { return true }
        let zh = ["只读", "无法创建文件", "无法写入", "没有写入权限", "无写入权限", "写不了文件", "权限不足", "无法直接在"]
        return zh.contains(where: { text.contains($0) })
    }

    /// 工作目录当前未提交/未跟踪的文件集合(git porcelain,**含全部文件**不止源码)。
    /// 返回 nil = 非 git 仓(没法自动核验落地)。链路验收用它 diff 出"本次真落了哪些文件"。
    nonisolated static func dirtyFileSet(workingDir: String) async -> Set<String>? {
        let dir = workingDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        for git in gitCandidatePaths() {
            let inside = await runCapturing(git, ["-C", dir, "rev-parse", "--is-inside-work-tree"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if inside == "false" { return nil }   // 非 git 仓
            guard inside == "true" else { continue }   // 空=该 git 没跑成,试下一个
            let porcelain = await runCapturing(git, ["-C", dir, "status", "--porcelain", "--untracked-files=all"])
            let paths = porcelain.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
                let s = String(line)
                guard s.count > 3 else { return nil }
                var p = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let arrow = p.range(of: " -> ") { p = String(p[arrow.upperBound...]) }
                return p.isEmpty ? nil : p
            }
            return Set(paths)
        }
        return nil
    }

    /// 刷新输入框里被声明式 `@` 到的 agent/插件芯片(驱动输入框上方"将编排"提示条,让 agent 调用在聊天框里醒目可见)。
    /// 在 `onChange(of: prompt)` 调;仅当含 `@` 才读盘解析(避免每次按键 I/O)。
    func refreshInvocationChips() {
        guard prompt.contains("@") else {
            if !detectedInvocationChips.isEmpty { detectedInvocationChips = [] }
            return
        }
        let plugins = invocablePlugins()
        let chain = LingShuDeclarativeInvocation.detectChain(prompt, plugins: plugins)
        let chips: [LingShuInvocationChip] = chain.compactMap { step in
            guard let inv = plugins.first(where: { $0.id == step.id }) else { return nil }
            if inv.kind == .agent {
                let aid = inv.id.hasPrefix("agent:") ? String(inv.id.dropFirst("agent:".count)) : inv.id
                let role = LingShuAgentPluginStore.plugin(id: aid)?.role.rawValue ?? "agent"
                return .init(name: inv.displayName, role: role, isAgent: true)
            }
            return .init(name: inv.displayName, role: "插件", isAgent: false)
        }
        if chips != detectedInvocationChips { detectedInvocationChips = chips }
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
