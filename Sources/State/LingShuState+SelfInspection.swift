import Foundation

/// **灵枢自检接进 LingShuState**:把策展的分层架构 + **运行时实时能力**(当前大脑/工具/agent插件/技能/记忆/自主/感知)
/// 拼成一份 `LingShuSelfInspection`,供 ① 大脑 `self_inspect` 工具拉准确自我认知(答自指/规划/自进化用);② 配置面板展示。
@MainActor
extension LingShuState {

    /// 实时拼装当前自检快照(架构相对稳定 + 能力按此刻状态拉取)。
    func assembleSelfInspection() -> LingShuSelfInspection {
        var capabilities: [LingShuSelfInspection.Section] = []

        // 大脑(可换)。
        var brainItems = ["当前大脑:\(modelProvider) / \(modelName)"]
        if shouldAttemptNativeMultimodalForCurrentModel() {
            brainItems.append("原生多模态:本通道默认尝试 image_url 直发")
        } else if isCurrentModelMarkedNativeMultimodalUnsupported() {
            brainItems.append("原生多模态:已确认不可用，附件走图片解析降级")
        }
        brainItems.append("大脑可热切换、换脑后记忆延续(codex/claude 是 agent 插件,不是大脑)")
        capabilities.append(.init(title: "🧠 大脑", items: brainItems))

        // 工具(核心恒可用 + 长尾按需 search_tools 激活)。
        let core = LingShuToolCatalog.coreToolNames.sorted().joined(separator: "、")
        capabilities.append(.init(title: "🛠 工具", items: [
            "核心(恒可用):\(core)",
            "原生 Computer Use:按应用读取 AX 语义快照、用元素索引操作、动作后回读验证；不依赖 Codex",
            "按需激活(search_tools):浏览器自动化、坐标截屏兜底、演示放映、会议纪要、定时调度、外设/家电控制、author_component 自造工具 等",
        ]))

        // 已注册的 agent 插件(被告知本机有→注册)。自检展示的是**运行时状态**:
        // 可用 / 不可用 / 未探活分清楚,避免把"登记过"误读成"当前可调度"。
        let agents = LingShuAgentPluginStore.load()
        if agents.isEmpty {
            capabilities.append(.init(title: "🤝 agent 插件状态", items: ["(暂无;跟我说『本机有 X,可执行…,调用…』即注册)"]))
        } else {
            // 每个 agent 后挂上它**自带的已启用子能力**(适配器发现的,如 codex 的 picsart/film-visual-pipeline 出图)——
            // 让大脑自检/路由时知道"该 agent 能干这些专长事",而不是自己硬扛(如出图)。
            let availableCount = agents.filter { $0.available == true && $0.isAvailableNow }.count
            let unavailableCount = agents.filter { !$0.isAvailableNow }.count
            let unverifiedCount = agents.filter { $0.available == nil && $0.executableExists }.count
            capabilities.append(.init(title: "🤝 agent 插件状态(\(availableCount) 可用 / \(unverifiedCount) 未探活 / \(unavailableCount) 不可用)",
                items: agents.map { agent in
                    let caps = agent.isCallableNow
                        ? agentCapabilities(for: agent.id).filter { $0.enabled && $0.installed }.map(\.name)
                        : []
                    let suffix = caps.isEmpty ? "" : " · 自带能力:\(caps.prefix(8).joined(separator: "、"))" + (caps.count > 8 ? "…" : "")
                    return agentInspectionLine(agent, suffix: suffix)
                }))
        }

        // 已学会的过程技能。
        let skills = LingShuProcedureSkillRouter.loadProcedures()
        if !skills.isEmpty {
            capabilities.append(.init(title: "🎯 已学技能(\(skills.count))",
                                      items: skills.prefix(10).map { $0.title }))
        }

        // 记忆规模。
        capabilities.append(.init(title: "🧩 记忆(知识图谱)", items: [
            "\(knowledgeGraph.count) 条原子知识(别名归一 + 双链 + 园丁自维护);additive 召回",
        ]))

        // 感知通道(可插拔)。
        capabilities.append(.init(title: "👁 感知通道", items: [
            "视觉:屏幕 / 摄像头;听觉:麦克风 / 系统声音;外接:可插拔传感汇聚",
            "实时流默认不归档;启用远程模型/感知服务时,数据处理遵循对应服务商条款",
        ]))

        // 自主 / 在岗 / 运行态。
        let onDuty = isStandingPersonOnDuty
        capabilities.append(.init(title: "⚙️ 运行态", items: [
            onDuty ? "在岗常驻中(听屏看屏、定时与无人值守)" : "待命(可上岗独立运行 / 挂定时 / 无人值守)",
            "自主阶段:\(autonomousRun.phase.rawValue);断网自动暂停→联网续跑",
        ]))

        return LingShuSelfInspection(
            oneLiner: "我是灵枢,由 Roy Zhao 打造的贾维斯式通用智能中枢——你说目标,判断 / 分派 / 执行 / 验收交给我。",
            architecture: LingShuSelfInspection.architectureOverview(),
            capabilities: capabilities
        )
    }

    /// 完整自检报告(markdown,面板/工具共用)。
    var selfInspectionReport: String { assembleSelfInspection().markdown() }

    /// **架构/能力/自检类问题 → 注入真实自我认知作引导**(grounding)。
    /// 因为弱脑(如 GLM)不会自动调 `self_inspect` 工具,这里确定性把真实架构 + 实时能力喂进上下文,
    /// 让大脑**grounded 在真实自我认知**上自然作答(不瞎猜、不背罐头),便于后期开展工作。简单「你是谁」不触发(那由自指引导处理)。
    func selfInspectionGuidance(for prompt: String) -> String? {
        let n = LingShuMemoryTextToolkit.normalize(prompt)
        let signals = ["架构", "自检", "怎么搭", "你的设计", "你的能力", "能做什么", "能做哪些", "能干什么",
                       "掌握自己", "你的工具", "有什么能力", "你会什么", "你怎么工作", "你的模块", "你的组成"]
        guard signals.contains(where: { n.contains($0) }) else { return nil }
        return """
        【你的真实自我认知·grounded(据此自然真诚地答,别背模板也别瞎编)】
        \(assembleSelfInspection().markdown())

        回答时:结合上面**真实的架构与当前能力**,用户问得多细就答多细;**别暴露底层模型名**;别逐条干巴巴复述,像个真正的 AGI 助理那样组织成自然、有条理的介绍。
        """
    }

    /// **`self_inspect` 工具**:让大脑随时调用、拉取自己的整体架构 + 实时能力——
    /// 答"你是谁/你能做什么/你怎么搭的"、做规划("我能不能做成X、缺什么")、自我进化时,基于**真实自我认知**而非瞎猜。
    func selfInspectTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "self_inspect",
            description: "**自检·掌握你自己**:返回灵枢当前的整体架构(分层设计)+ 实时能力(当前大脑、可用工具、已接入 agent 插件、已学技能、记忆规模、感知通道、自主/在岗运行态)。答自指问题(你是谁/能做什么/怎么搭的)、规划任务前评估自身能力、或自我进化时调它,据真实自我认知作答与决策,别凭空猜。无需入参。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{},\"required\":[]}"
        ) { [weak self] _ in
            guard let self else { return "自检环境不可用。" }
            return await MainActor.run { self.assembleSelfInspection().markdown() }
        }
    }

    /// 自检面板/工具展示用的 agent 状态文案。这里不发起子进程,只读持久健康状态与可执行文件事实。
    func agentInspectionLine(_ agent: LingShuAgentPlugin, suffix: String = "") -> String {
        let role = agent.role.rawValue
        let checked = agent.lastCheckedAt.map { " · 上次探活:\(Self.agentHealthDateFormatter.string(from: $0))" } ?? ""
        if !agent.executableExists {
            return "❌ @\(agent.displayName)(\(role)) · 不可用:找不到可执行文件 \(agent.executable)\(checked)\(suffix)"
        }
        if agent.available == false {
            let reason = (agent.unavailableReason?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "探活/运行失败"
            return "❌ @\(agent.displayName)(\(role)) · 不可用:\(reason)\(checked)\(suffix)"
        }
        if agent.available == true {
            return "✅ @\(agent.displayName)(\(role)) · 可用\(checked)\(suffix)"
        }
        return "⚪️ @\(agent.displayName)(\(role)) · 未探活:可执行文件存在,尚未完成运行验证\(suffix)"
    }

    /// 自检 live 刷新:对已注册 agent 做一次短探活,把认证/额度/令牌/文件缺失等通用故障回写到插件库。
    func refreshAgentPluginAvailabilityForSelfInspection() async {
        let agents = LingShuAgentPluginStore.load()
        guard !agents.isEmpty else { return }
        let wd = agentWorkingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : agentWorkingDirectory
        await withTaskGroup(of: Void.self) { group in
            for agent in agents {
                group.addTask {
                    let probe = await LingShuAgentPluginStore.probeAvailability(agent, workingDirectory: wd)
                    if probe.ok {
                        _ = LingShuAgentPluginStore.markAvailable(id: agent.id)
                    } else {
                        _ = LingShuAgentPluginStore.markUnavailable(id: agent.id, reason: probe.reason)
                    }
                }
            }
            await group.waitForAll()
        }
        refreshAgentCapabilities(force: true)
        invalidateInvocablePluginCatalog()
    }

    /// 避免每次打开自检都打扰外部 agent;只有没探过或状态过旧时才自动刷新。
    func agentPluginSelfInspectionNeedsRefresh(maxAge: TimeInterval = 30 * 60) -> Bool {
        let now = Date()
        return LingShuAgentPluginStore.load().contains { agent in
            guard agent.executableExists else { return true }
            guard let last = agent.lastCheckedAt else { return true }
            return now.timeIntervalSince(last) > maxAge
        }
    }

    private static let agentHealthDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
