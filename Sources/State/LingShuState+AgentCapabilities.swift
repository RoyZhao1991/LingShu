import Foundation

/// **第三方 agent 子能力链路(适配器,2026-06-29)**:把每个已注册 agent 自己的子插件/技能(Codex 插件、Claude 技能…)
/// 发现 → 归一 → 缓存,供后续"双向曝光(@/+ 菜单 + 大脑 grounding)"和"能力感知调用"复用。内核通用一套、不点名某个 agent。
@MainActor
extension LingShuState {

    /// 刷新所有已注册 agent 的子能力。发现命令是只读枚举,但走子进程会阻塞 → 后台跑、回主线程写缓存。
    /// `force=false` 时有 TTL 节流(默认 5 分钟内不重复发现);注册新 agent / 用户点"刷新"用 `force=true`。
    func refreshAgentCapabilities(force: Bool = false) {
        if !force, let at = agentCapabilitiesRefreshedAt, Date().timeIntervalSince(at) < 300 { return }
        let agents = LingShuAgentPluginStore.load().filter { $0.capabilities?.discover != nil && $0.executableExists }
        guard !agents.isEmpty else { return }
        agentCapabilitiesRefreshedAt = Date()   // 先占位,避免并发重复发现
        Task.detached(priority: .utility) {
            var all: [LingShuAgentCapability] = []
            for agent in agents { all.append(contentsOf: LingShuAgentCapabilityDiscovery.discover(agent)) }
            let snapshot = all
            await MainActor.run {
                self.discoveredAgentCapabilities = snapshot
                let enabled = snapshot.filter { $0.enabled && $0.installed }.count
                lingShuControlLog("agent能力发现: 归一 \(snapshot.count) 项,已启用 \(enabled) 项 | " +
                    Set(snapshot.map(\.agentID)).sorted().joined(separator: ","))
            }
        }
    }

    /// **P3 能力感知调用(2026-06-29)**:定向让某 agent 用它**自带的某个子能力**完成任务。
    /// 已启用 → 增强目标(明确点名用这个能力)+ 派给该 agent(走现成角色管线,maker=该 agent)。
    /// 未安装 → **供应链红线:不自动装**,提示用户确认(部分能力还需对应账号登录)。
    func dispatchAgentCapability(agentID: String, capabilityID: String, task: String) {
        guard let agent = LingShuAgentPluginStore.plugin(id: agentID) else {
            chatMessages.append(.init(speaker: "灵枢", text: "⚠️ 找不到已注册 agent「\(agentID)」。", isUser: false)); return
        }
        let cap = discoveredAgentCapabilities.first { $0.agentID == agentID && $0.id == capabilityID }
        let capName = cap?.name ?? capabilityID
        if let cap, !cap.installed {
            chatMessages.append(.init(speaker: "灵枢",
                text: "「\(capName)」是 \(agent.displayName) 的能力,但**尚未安装**。安装=从市场拉第三方代码(供应链红线),需要你明确确认;部分能力(如 picsart)还需对应账号登录。要装就回「确认安装 \(capName)」。",
                isUser: false))
            return
        }
        appendTrace(kind: .route, actor: "声明式调用", title: "@agent·能力 直达", detail: "\(agent.displayName)·\(capName)")
        // **「用某能力」的定向只进 maker 的子任务指令,不冒充用户的"需求方"消息**:
        // 记录的 需求方/标题/GoalSpec 用**用户原话**(task),否则会显示成"请用你自带的…"让用户以为是自己说的(实测 bug)。
        let makerInstruction = "请用你自带的「\(capName)」能力来做(这是你的专长插件,优先用它,别退化成通用代码硬画/硬凑):\n\(task)"
        // **确定的两角色管线:该 agent 当 maker(它才会被真·调用执行,而非靠灵枢的脑去 delegate)+ 灵枢当 checker**。
        // 不走 dispatchIsolatedTask(maker=外部 agent 时靠大脑自觉 run_agent,实测 DeepSeek 不 delegate、自己 Pillow 画);
        // 也不让大脑规划角色(单 agent 常返 <2 → 整条早退 + 留"记录不存在"弹窗)。给固定 steps 直接跑。
        let builder = expertProfileRegistry.profile(for: task)        // 默认=工程执行专家
        let reviewer = expertProfileRegistry.reviewerProfile()
        let steps = [
            LingShuRoleStep(roleID: builder.id, roleTitle: builder.title, agentID: agent.id, agentName: agent.displayName, subtask: makerInstruction),
            LingShuRoleStep(roleID: reviewer.id, roleTitle: reviewer.title, agentID: nil, agentName: "灵枢", subtask: "按目标核验 \(agent.displayName) 用「\(capName)」产出的结果,不合格打回。")
        ]
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isModelExecuting = true
            defer { self.isModelExecuting = false; self.drainSerialInputsIfIdle() }
            _ = await self.runRolePipelineDispatch(task: task, agents: [(id: agent.id, name: agent.displayName)], fixedSteps: steps)
        }
    }

    /// **安装一个 agent 子能力(供应链红线:仅在用户明确确认后调用)**。装完刷新发现,让它从此可用/可调。
    func installAgentCapabilityConfirmed(agentID: String, capabilityID: String) {
        guard let agent = LingShuAgentPluginStore.plugin(id: agentID) else { return }
        let capName = discoveredAgentCapabilities.first { $0.agentID == agentID && $0.id == capabilityID }?.name ?? capabilityID
        chatMessages.append(.init(speaker: "灵枢", text: "正在安装 \(agent.displayName) 能力「\(capName)」…", isUser: false))
        Task.detached(priority: .userInitiated) {
            let r = LingShuAgentCapabilityDiscovery.install(agent: agent, capabilityID: capabilityID)
            await MainActor.run {
                self.chatMessages.append(.init(speaker: "灵枢",
                    text: r.ok ? "✅ 「\(capName)」安装完成。" : "⚠️ 「\(capName)」安装可能失败:\(r.output.suffix(160))", isUser: false))
                self.refreshAgentCapabilities(force: true)   // 重新发现,刷新启用/已装状态
            }
        }
    }

    /// 某 agent 的子能力(已启用的在前,便于展示/优先用)。
    func agentCapabilities(for agentID: String) -> [LingShuAgentCapability] {
        discoveredAgentCapabilities
            .filter { $0.agentID == agentID }
            .sorted { ($0.enabled ? 0 : 1, $0.name) < ($1.enabled ? 0 : 1, $1.name) }
    }

    /// 给大脑能力 grounding 用的一段文本:已接入 agent 各自带的子能力(只列已启用的,避免噪声)。
    /// 让自动路由也"认得"——例如用户说"生成一张图",大脑知道某 agent 有出图能力,而不是自己用 Pillow 硬画。
    func agentCapabilitiesGroundingText() -> String {
        let enabled = discoveredAgentCapabilities.filter { $0.enabled && $0.installed }
        guard !enabled.isEmpty else { return "" }
        let byAgent = Dictionary(grouping: enabled, by: \.agentID)
        var lines: [String] = []
        for (agentID, caps) in byAgent.sorted(by: { $0.key < $1.key }) {
            let names = caps.map(\.name).sorted().joined(separator: "、")
            lines.append("- @\(agentID) 自带可用子能力:\(names)")
        }
        return "【已接入 agent 自带的专长子能力】需要这些专长(如出图/视频/表格/PPT)时,**优先把活派给对应 agent 让它用自带能力做**(显式 @它·能力 或你判断调度),别自己用代码硬扛(如出图别 Pillow 画几何拼贴)。\n"
            + lines.joined(separator: "\n")
    }
}
