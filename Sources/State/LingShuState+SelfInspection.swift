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
        if selectedModelPreset?.supportsNativeMultimodal == true {
            brainItems.append("原生多模态(图片可直接喂主模型)")
        }
        brainItems.append("大脑可热切换、换脑后记忆延续(codex/claude 是 agent 插件,不是大脑)")
        capabilities.append(.init(title: "🧠 大脑", items: brainItems))

        // 工具(核心恒可用 + 长尾按需 search_tools 激活)。
        let core = LingShuToolCatalog.coreToolNames.sorted().joined(separator: "、")
        capabilities.append(.init(title: "🛠 工具", items: [
            "核心(恒可用):\(core)",
            "按需激活(search_tools):浏览器自动化、屏幕截屏点按、演示放映、会议纪要、定时调度、外设/家电控制、author_component 自造工具 等",
        ]))

        // 已注册的 agent 插件(被告知本机有→注册)。
        let agents = LingShuAgentPluginStore.load()
        if agents.isEmpty {
            capabilities.append(.init(title: "🤝 已接入 agent 插件", items: ["(暂无;跟我说『本机有 X,可执行…,调用…』即注册)"]))
        } else {
            capabilities.append(.init(title: "🤝 已接入 agent 插件(\(agents.count))",
                                      items: agents.map { "@\($0.displayName)(\($0.role.rawValue))\($0.isAvailableNow ? "" : " · 当前不可用")" }))
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
            "本地解析路由 + 云端零留存",
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
}
