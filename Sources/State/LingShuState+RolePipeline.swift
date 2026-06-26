import Foundation

/// 一个角色步骤(大脑规划产出):角色 + 分配的 agent(可插孔)+ 子任务。
struct LingShuRoleStep: Equatable, Sendable {
    let roleID: String
    let roleTitle: String
    let agentID: String?    // nil = 灵枢本体执行该角色
    let agentName: String?
    let subtask: String
}

/// **通用多角色管线(用户定调 2026-06-26)**:大脑读「现有角色注册表 `allProfiles`」+「可用 agent」**规划任务**——
/// 决定**启用哪些角色**(用不到的不启用)、各干什么子任务、用**哪个 agent**执行(可插孔:codex 当架构师、claude 开发、
/// codex 验收…),按序执行,评审官把关。**角色增删自适应**(读注册表,零写死)。是 maker/checker 二角色的 N 角色推广。
@MainActor
extension LingShuState {

    private struct RoleStepJSON: Codable { let role: String?; let agent: String?; let subtask: String? }

    /// 大脑规划角色管线:读现有角色 + 可用 agent → 决定启用哪些角色、各干啥、谁来干。返回空=不需要多角色(走简单流程)。
    func planRolePipeline(task: String, agents: [(id: String, name: String)]) async -> [LingShuRoleStep] {
        let roles = expertProfileRegistry.allProfiles
        guard !roles.isEmpty else { return [] }
        let roleList = roles.map { "- \($0.id):\($0.title) —— \($0.mission)" }.joined(separator: "\n")
        let agentList = (agents.map { "- \($0.name)(id=\($0.id))" } + ["- 灵枢(本体,id=灵枢)"]).joined(separator: "\n")
        let system = """
        你是任务规划器。下面是**当前可用的角色**和**可用的执行 agent**。请**语义判断**(别抠关键词):
        ① 这个任务需要**启用哪些角色**(用不到的别启用——简单代码任务可能只要 工程执行 + 评审官;复杂工程才上 项目经理/架构师);
        ② 每个启用的角色干**什么子任务**;③ 用**哪个 agent**执行(或灵枢自己)——这是可插孔的,同一角色可由任意 agent 担任。
        - 角色**按依赖顺序**排列(前序产出给后续承接,如 架构师→工程执行→评审官)。
        - 交付类任务**尽量带评审官**把关。任务很简单(纯对话/答疑)就返回空数组 `[]`。
        **只输出一个 JSON 数组**,别的都不要:[{"role":"<角色id>","agent":"<agent id 或 灵枢>","subtask":"<这个角色干什么>"}]
        【当前可用角色】
        \(roleList)
        【当前可用 agent】
        \(agentList)
        """
        let session = LingShuAgentSession(id: "plan-\(UUID().uuidString.prefix(6))", system: system,
                                          tools: [], model: makeAgentModelAdapter(), maxTurns: 1)
        guard case .completed(let raw) = await session.send(task) else { return [] }
        let text = LingShuReasoningText.stripThinkTags(raw)
        guard let s = text.firstIndex(of: "["), let e = text.lastIndex(of: "]"),
              let data = String(text[s...e]).data(using: .utf8),
              let arr = try? JSONDecoder().decode([RoleStepJSON].self, from: data) else { return [] }
        return arr.compactMap { j -> LingShuRoleStep? in
            guard let roleStr = j.role,
                  let role = roles.first(where: { $0.id.caseInsensitiveCompare(roleStr) == .orderedSame || $0.title == roleStr })
            else { return nil }
            let a = agents.first { $0.id.caseInsensitiveCompare(j.agent ?? "") == .orderedSame || $0.name.caseInsensitiveCompare(j.agent ?? "") == .orderedSame }
            return LingShuRoleStep(roleID: role.id, roleTitle: role.title, agentID: a?.id, agentName: a?.name, subtask: (j.subtask?.isEmpty == false) ? j.subtask! : task)
        }
    }

    /// 按规划执行角色管线:**建设角色按序跑**(产出承接),然后**评审官把关**——评审官判不过→退回最后一个建设角色返工→
    /// 评审官再验,**通过才交付**(有界轮次)。每个角色作为**命名参与方**可见。返回(产出汇总, 是否通过)。
    func runRolePipeline(recordID rid: String, task: String, steps: [LingShuRoleStep]) async -> (summary: String, passed: Bool) {
        let roles = expertProfileRegistry.allProfiles
        let reviewerID = expertProfileRegistry.reviewerProfile().id   // 评审官角色 id(从注册表取,非关键词)
        let builders = steps.filter { $0.roleID != reviewerID }       // 建设角色(架构/开发…)
        let reviewers = steps.filter { $0.roleID == reviewerID }      // 评审官(可多个)
        var prior = ""
        appendTrace(kind: .route, actor: "角色规划", title: "多角色管线(\(steps.count) 环)",
                    detail: steps.map { "\($0.roleTitle)=\($0.agentName ?? "灵枢")" }.joined(separator: " → "))

        // 跑单个角色(agent 或灵枢会话),记参与方,返回产出。
        func runRole(_ step: LingShuRoleStep, tag: String, extra: String) async -> String {
            let rolePrompt = roles.first { $0.id == step.roleID }?.promptBlock ?? ""
            let objective = """
            你在本任务里担任角色:**\(step.roleTitle)**。
            \(rolePrompt)
            你这一环的子任务:\(step.subtask)
            \(extra)
            \(prior.isEmpty ? "" : "前序角色的产出(承接它往下做,别推翻重来):\n\(prior.prefix(2500))")
            产物落到当前工作目录;最后用一句话交代你这一环的结论 / 产出。
            """
            let actor = step.agentName ?? "灵枢"
            appendTaskRecordMessage(rid, actor: actor, role: "\(step.roleTitle)·\(tag)", kind: .agent,
                                    text: "▶ \(actor) 担任「\(step.roleTitle)」:\(step.subtask.prefix(80))")
            let output: String
            if let agentID = step.agentID, let plugin = LingShuAgentPluginStore.plugin(id: agentID) {
                switch await LingShuAgentPluginStore.run(plugin, objective: objective, workingDirectory: agentWorkingDirectory) {
                case .completed(let t): output = t
                case .failure(let f):   output = "(\(plugin.displayName) 未完成:\(f))"
                }
            } else {
                let tools = agentBuiltinTools(recordIDProvider: { rid }, executionPolicy: dispatchedTaskExecutionPolicy)
                let session = makeAgentSession(id: "role-\(UUID().uuidString.prefix(6))", system: rolePrompt,
                                               tools: tools, model: makeAgentModelAdapter(), maxTurns: 40)
                output = Self.runResultText(await session.send(objective))
            }
            return output
        }

        // 1) 建设角色按序跑一遍。
        for (i, step) in builders.enumerated() {
            if Task.isCancelled || batchInterruptRequested { break }
            let o = await runRole(step, tag: "上岗(第\(i + 1)环)", extra: "")
            appendTaskRecordMessage(rid, actor: step.agentName ?? "灵枢", role: "\(step.roleTitle)·产出", kind: .result, text: String(o.prefix(1500)))
            prior += "\n【\(step.roleTitle)·\(step.agentName ?? "灵枢")】\n\(o.prefix(1500))"
        }
        // 没评审官 → 没把关,直接交付(大脑没规划评审就不强加)。
        guard !reviewers.isEmpty else { return (prior, true) }

        // 2) 评审官把关 → 不过退回最后一个建设角色返工 → 再验(有界 2 轮)。**通过才交付,这是 LOOP 闭环。**
        let maxRounds = 2
        for round in 0..<maxRounds {
            if Task.isCancelled || batchInterruptRequested { break }
            var fails: [String] = []
            for rev in reviewers {
                let v = await runRole(rev, tag: "验收(第\(round + 1)轮)", extra: "你是把关方,独立核验前序产出是否达成目标(读代码/跑测试/运行)。**结论第一行只写「通过」或「不通过」**,其后列问题。")
                let passed = Self.checkerVerdictPassed(v)
                appendTaskRecordMessage(rid, actor: rev.agentName ?? "灵枢",
                                        role: passed ? "\(rev.roleTitle)·通过" : "\(rev.roleTitle)·需修正(第\(round + 1)轮)",
                                        kind: passed ? .result : .agent, text: String(v.prefix(1200)))
                if !passed { fails.append("【\(rev.roleTitle)】\(v.prefix(400))") }
                prior += "\n【\(rev.roleTitle)·\(passed ? "通过" : "需修正")】\n\(v.prefix(800))"
            }
            if fails.isEmpty { return (prior, true) }                 // 全部评审通过 → 交付
            guard round + 1 < maxRounds, let producer = builders.last else {
                return (prior + "\n\n(评审未通过且已达返工上限,如实交还,未交付。)", false)
            }
            // 退回最后一个建设角色返工(带评审意见)。
            let critique = fails.joined(separator: "\n")
            let fixed = await runRole(producer, tag: "返工(第\(round + 1)轮)", extra: "**评审未通过,据下面意见返工修正(必须真改到能通过):**\n\(critique.prefix(1000))")
            appendTaskRecordMessage(rid, actor: producer.agentName ?? "灵枢", role: "\(producer.roleTitle)·返工交付(第\(round + 1)轮)", kind: .result, text: String(fixed.prefix(1500)))
            prior += "\n【\(producer.roleTitle)·返工】\n\(fixed.prefix(1500))"
        }
        return (prior, false)
    }
}
