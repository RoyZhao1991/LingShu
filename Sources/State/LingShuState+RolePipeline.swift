import Foundation

/// 上次角色管线用的 agent(供续接继承:延续之前任务时沿用同样的 agent)。
struct LingShuRoleAgentRef: Equatable, Sendable { let id: String; let name: String }

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

    /// 规划 + 跑角色管线的**完整派发**(建可打开的子线程记录、跑、收尾、记下用的 agent 供续接继承)。
    /// 返回 true=确实跑了多角色管线(≥2 角色);false=没规划出多角色(调用方回退 maker/checker)。
    @discardableResult
    func runRolePipelineDispatch(task: String, agents: [(id: String, name: String)], existingBubbleID: UUID? = nil) async -> Bool {
        let steps = await planRolePipeline(task: task, agents: agents)
        guard steps.count >= 2 else { return false }
        lastPipelineAgents = agents.map { LingShuRoleAgentRef(id: $0.id, name: $0.name) }   // 记下供续接继承
        lastPipelineTask = task
        let rid = createTaskExecutionRecord(for: task)
        let subID = "pipe-\(rid.suffix(8))"
        agentSubTaskRecords[subID] = rid   // 注册成可打开的派发子线程
        if goalSpecEnabled { bindGoalSpec(LingShuGoalSpec(objective: task, kind: .task), to: rid) }
        appendTaskRecordMessage(rid, actor: "灵枢", role: "派生子任务", kind: .router,
                                text: "派生角色管线子线程:" + steps.map { "\($0.roleTitle)(\($0.agentName ?? "灵枢"))" }.joined(separator: " → "))
        let intake = "🔧 已规划角色管线:" + steps.map { "\($0.roleTitle)(\($0.agentName ?? "灵枢"))" }.joined(separator: " → ")
        let bid: UUID
        if let existingBubbleID, let idx = chatMessages.firstIndex(where: { $0.id == existingBubbleID }) {
            chatMessages[idx].text = intake; chatMessages[idx].isLoading = true; chatMessages[idx].taskRecordID = rid; bid = existingBubbleID
        } else {
            let bubble = ChatMessage(speaker: "灵枢", text: intake, isUser: false, isLoading: true, taskRecordID: rid)
            chatMessages.append(bubble); bid = bubble.id
        }
        dispatchedTaskBubbles[rid] = bid
        let (result, passed) = await runRolePipeline(recordID: rid, task: task, steps: steps)
        agentSubTaskRecords[subID] = nil
        if let idx = chatMessages.firstIndex(where: { $0.id == bid }) {
            chatMessages[idx].text = intake
                + (passed ? "\n\n✅ 管线完成,评审通过、已交付。\n" : "\n\n⚠️ 评审未通过,已交还(未交付,需修正后重验)。\n")
                + String(result.suffix(500))
            chatMessages[idx].isLoading = false
        }
        finishTaskRecord(rid, status: passed ? .verified : .partial,
                         summary: (passed ? "角色管线评审通过:" : "角色管线评审未通过(部分完成):") + steps.map(\.roleTitle).joined(separator: "→"))
        return true
    }

    /// **续接继承(用户定调:延续之前任务应沿用同样的 agent,不重置回灵枢)**:大脑判断这条新消息是不是上一个角色管线任务的延续。
    /// 非关键词——让大脑读懂「把刚才那个做完 / 运行起来验收 / 继续」这类延续意图。是→调用方用上次 agent 再跑管线。
    func isContinuationOfLastPipeline(prompt: String) async -> Bool {
        guard !lastPipelineAgents.isEmpty, !lastPipelineTask.isEmpty else { return false }
        let agentNames = lastPipelineAgents.map(\.name).joined(separator: "、")
        let system = """
        上一个任务是「\(lastPipelineTask.prefix(100))」,由这些 agent 协作完成:\(agentNames)。
        现在用户发来一条新消息。请**语义判断**:这条新消息是不是**上一个任务的延续 / 接着把它做完 / 对它的修改或验收**?
        (如「把刚才那个做完」「运行起来给我验收」「继续」「再改改」都是延续;另起一件全新的事不是。)
        只输出 JSON:{"continuation": true 或 false}
        """
        let session = LingShuAgentSession(id: "cont-\(UUID().uuidString.prefix(6))", system: system,
                                          tools: [], model: makeAgentModelAdapter(), maxTurns: 1)
        guard case .completed(let raw) = await session.send(prompt) else { return false }
        let t = LingShuReasoningText.stripThinkTags(raw).lowercased()
        return t.range(of: "\"continuation\"\\s*:\\s*true", options: .regularExpression) != nil
    }

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
                // 验收遇模型通道故障(超时/网络)≠ 验收驳回:产物已落地,暂停待重验,别误判需修正去返工。
                if let f = LingShuModelServiceFailure.decodeReason(v), f.shouldAutoResume {
                    appendTaskRecordMessage(rid, actor: rev.agentName ?? "灵枢", role: "\(rev.roleTitle)·验收暂停(模型通道故障)", kind: .warning,
                                            text: "验收时\(f.userFacingMessage)（产物已落地,非需修正;通道恢复后可重验)。")
                    return (prior + "\n\n(验收遇模型通道故障,产物已落地、待重验,未误判需修正。)", false)
                }
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
