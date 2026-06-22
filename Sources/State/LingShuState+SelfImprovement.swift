import Foundation

/// 通用中枢 P6·**自我进化闭环**接线(有界、人批)(见 [[LingShuSelfImprovement]])。
/// 挖 P4 经验库的反复弱点 → 生成**待批准**改进提案(默认 pending,**不自动采纳**);
/// **人批准**后才把提案变成一条真任务去建(走既有 task 派发 → author_component/discover_skill/连接器,**沙箱+安全门+完成闸**),
/// 采纳的能力可禁用回滚。**绝不自改核心 Swift、绝不自动执行未审代码**。
@MainActor
extension LingShuState {

    private static let improvementProposalsKey = "lingshu.self.improvements"

    /// 配置入口:开/关**自我进化总开关**(持久化跨重启)。开启属高风险授权(UI 端会先弹风险提示再调这里 true)。
    /// 关 → P6 完全静默(不挖/不提/不采纳);开 → 自检弱点提待批提案,采纳仍逐条人批、可一键回退。
    func setSelfEvolutionEnabled(_ on: Bool) {
        guard selfEvolutionEnabled != on else { return }
        selfEvolutionEnabled = on
        UserDefaults.standard.set(on, forKey: "lingshu.selfEvolution")
        appendTrace(kind: on ? .warning : .system, actor: "自我进化",
                    title: on ? "已开启(高风险能力)" : "已关闭",
                    detail: on ? "灵枢将自检反复弱点并主动提改进提案;采纳仍需你逐条批准、每条可一键回退。"
                               : "已关闭:不挖弱点、不提案、不采纳,零行为(默认态)。")
    }

    func improvementProposals() -> [LingShuImprovementProposal] {
        guard let data = UserDefaults.standard.data(forKey: Self.improvementProposalsKey),
              let list = try? JSONDecoder().decode([LingShuImprovementProposal].self, from: data) else { return [] }
        return list
    }

    private func persistImprovementProposals(_ list: [LingShuImprovementProposal]) {
        if let data = try? JSONEncoder().encode(Array(list.suffix(100))) {
            UserDefaults.standard.set(data, forKey: Self.improvementProposalsKey)
        }
    }

    /// 挖反复弱点(纯,从 P4 经验库)。
    func mineSelfImprovementPatterns() -> [LingShuImprovementPattern] {
        LingShuSelfImprovementMiner.detectPatterns(goalExperiences())
    }

    /// 生成自我改进提案:挖弱点 → 拟有界建议 → 存 **pending** + 落 trace + 一条提示气泡。**不自动采纳**。
    /// 去重:同 theme 已有非 rejected 提案则跳过。返回新增条数。
    @discardableResult
    func proposeSelfImprovements() -> Int {
        guard selfEvolutionEnabled else { return 0 }   // 自我进化关 → 不提案(零行为)
        let patterns = mineSelfImprovementPatterns()
        guard !patterns.isEmpty else { return 0 }
        var list = improvementProposals()
        var added = 0
        for p in patterns where !list.contains(where: { $0.theme == p.theme && $0.status != .rejected }) {
            list.append(.init(theme: p.theme, occurrences: p.occurrences, suggestion: LingShuSelfImprovementMiner.suggestion(for: p)))
            added += 1
        }
        guard added > 0 else { return 0 }
        persistImprovementProposals(list)
        appendTrace(kind: .system, actor: "自我进化", title: "发现可改进点", detail: "新增 \(added) 条改进提案(待你批准,不自动采纳)")
        chatMessages.append(.init(speaker: "灵枢", text: "🔧 我自检发现 \(added) 个反复受挫的点,拟了改进提案(自写工具/装技能/接连接器,沙箱+安全门)。**你批准我才动手**,采纳后可回滚。", isUser: false))
        return added
    }

    /// **P6 自动触发**(无模型调用——挖掘是纯字符二元组聚类):**非成功**终态经验落库后立即挖一次反复弱点。
    /// 某类目标失败到第 2 次(成簇 ≥2)即自动生成**待批**提案;`proposeSelfImprovements` 去重 → 同主题只提一次、
    /// **绝不自动采纳**。成功终态不触发(没必要)。门控同 `goalSpecEnabled`,关则零成本。挂在 `rememberGoalExperienceIfNeeded` 末尾。
    @discardableResult
    func autoMineSelfImprovementsOnFailure(outcome: String) -> Int {
        guard selfEvolutionEnabled else { return 0 }   // 自我进化总开关(默认关)→ 不自动挖
        let nonSuccess: Set<String> = ["未达标", "部分完成", "失败"]
        guard nonSuccess.contains(outcome) else { return 0 }
        let added = proposeSelfImprovements()
        if added > 0 {
            appendTrace(kind: .system, actor: "自我进化", title: "自动触发·反复弱点",
                        detail: "新失败经验落库 → 自动挖出 \(added) 条可改进点(待你批,未自动采纳)")
        }
        return added
    }

    /// **人批准**:把提案变成一条真任务去建(走既有 task 派发 → M1 沙箱+安全门+完成闸)。状态 → approved。
    /// **并**(P6+ 无界自进化闭环)把这条改进蒸成一条 **inactive 执行策略变体**登记进模块变体注册表——
    /// 默认不生效(符合"自进化产物先不生效、人一键切换才生效、出问题一键回退"原则),让采纳的经验可被随时启用/撤回。
    func approveSelfImprovement(id: String) {
        guard selfEvolutionEnabled else { return }   // 自我进化关 → 不采纳(高风险动作受总开关门控)
        var list = improvementProposals()
        guard let idx = list.firstIndex(where: { $0.id == id }), list[idx].status == .pending else { return }
        list[idx].status = .approved
        persistImprovementProposals(list)
        let prop = list[idx]
        appendTrace(kind: .result, actor: "自我进化", title: "已批准·派任务去建", detail: String(prop.theme.prefix(40)))
        registerImprovementAsVariant(prop)   // P6→变体联动:登记成可一键启用/回退的策略变体
        let prompt = "自我改进:我在「\(prop.theme)」这类目标上反复受挫(\(prop.occurrences) 次)。请补齐对应能力——优先 author_component 自写工具 / discover_skill 装现成技能 / 接连接器(都经沙箱+安全门),建好用最小验证确认真可用。"
        _ = submitTextInput(prompt, source: .plugin("自我进化"))
    }

    /// 把一条已批准的改进蒸成 **inactive 执行策略变体**登记(P6 采纳 → 变体注册表)。
    /// payload=据弱点拟的执行策略提示;source=authored;默认不激活(人到变体面板一键切换才热生效)。返回变体 id。
    @discardableResult
    func registerImprovementAsVariant(_ prop: LingShuImprovementProposal) -> String {
        let strategy = "【针对「\(prop.theme.prefix(40))」这类目标的执行策略(自进化采纳)】历史上在这类目标反复受挫 \(prop.occurrences) 次——这次:动手前先确认所需能力/前提是否齐备,缺就先走能力获取闭环(查已连MCP/装现成技能/自写组件/浏览器登录)并最小验证确实可用再推进;真依赖你拿不到的凭据/授权就一句话说清需要什么,绝不把没做成包装成完成。"
        let vid = registerModuleVariant(slotID: LingShuModuleSlots.executionGuidance,
                                        label: "自进化策略·\(prop.theme.prefix(16))",
                                        source: "authored", payload: strategy, activate: false)
        chatMessages.append(.init(speaker: "灵枢", text: "🧬 这条改进我已登记成一条**可一键启用的执行策略变体**(默认未启用,符合「先不生效、你批了再切」原则)。在「系统配置 → 技能 → 模块变体」里可一键切换生效 / 一键回退。", isUser: false))
        return vid
    }

    /// 人否决:状态 → rejected(同 theme 不再反复提案)。
    func rejectSelfImprovement(id: String) {
        var list = improvementProposals()
        guard let idx = list.firstIndex(where: { $0.id == id }), list[idx].status == .pending else { return }
        list[idx].status = .rejected
        persistImprovementProposals(list)
        appendTrace(kind: .system, actor: "自我进化", title: "已否决", detail: String(list[idx].theme.prefix(40)))
    }
}
