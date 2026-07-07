import Foundation

/// 上次角色管线用的 agent(供续接继承:延续之前任务时沿用同样的 agent)。
struct LingShuRoleAgentRef: Codable, Equatable, Sendable { let id: String; let name: String }

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
    /// `fixedSteps` 给定时**跳过大脑角色规划**,直接用这套确定的角色(如能力直达:某 agent 当 maker + 灵枢 当 checker)——
    /// 单 agent 场景大脑规划常返 <2 角色导致整条 dispatch 早退,确定步骤避开它。
    func runRolePipelineDispatch(
        task: String,
        agents: [(id: String, name: String)],
        existingBubbleID: UUID? = nil,
        fixedSteps: [LingShuRoleStep]? = nil,
        preflightGoalSpec: LingShuGoalSpec? = nil
    ) async -> Bool {
        // **立即建记录 + 绑气泡 + 注册线程(发出即开好、可打开、可见"执行中";别等规划那几秒)**——
        // 修「发完消息长延迟才出气泡」+「执行完才看到执行记录」:规划/执行都在记录已可见之后进行。
        let displayTask = preflightGoalSpec?.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? preflightGoalSpec!.objective
            : task
        let rid = createTaskExecutionRecord(for: displayTask)
        let subID = "pipe-\(rid.suffix(8))"
        agentSubTaskRecords[subID] = rid
        // **持有"管线驱动中"标记**:角色管线是直接 Task、不在 orchestrator 的 driveTasks 里,孤儿看门狗据此跳过(否则 ~20s 就把还在跑的它误收口成 .partial)。
        livePipelineRecordIDs.insert(rid)
        defer { livePipelineRecordIDs.remove(rid) }   // 任何返回路径(完成/早退/取消/抛错)都释放,不泄漏
        let bid: UUID
        if let existingBubbleID, let idx = chatMessages.firstIndex(where: { $0.id == existingBubbleID }) {
            chatMessages[idx].text = "🔧 正在理解任务、规划角色…"; chatMessages[idx].isLoading = true; chatMessages[idx].taskRecordID = rid; bid = existingBubbleID
        } else {
            let bubble = ChatMessage(speaker: "灵枢", text: "🔧 正在理解任务、规划角色…", isUser: false, isLoading: true, taskRecordID: rid)
            chatMessages.append(bubble); bid = bubble.id
        }
        dispatchedTaskBubbles[rid] = bid
        appendTaskRecordMessage(rid, actor: "灵枢", role: "中枢", kind: .core, text: "收到。理解任务、规划角色管线中…")
        openTaskRecord(rid)   // **发出即自动打开执行记录窗口**(用户要的「子线程直接开好、能看执行中」),不必再点「定位」
        // **真目标认知**:用 deriveGoalSpec 让大脑把请求**提炼成精炼目标 + 逐条可验收成功标准**(不是把原话照抄进去),
        // 供执行引导 + 评审官据此逐条核验。放窗口打开之后:先弹窗、再填目标认知。
        let boundGoalSpec: LingShuGoalSpec?
        if goalSpecEnabled {
            if let preflightGoalSpec {
                boundGoalSpec = preflightGoalSpec
                bindGoalSpec(preflightGoalSpec, to: rid)
            } else {
                boundGoalSpec = await deriveGoalSpec(for: task, taskRecordID: rid)
                bindGoalSpec(boundGoalSpec, to: rid)
            }
        } else {
            boundGoalSpec = nil
        }
        let executionTask = contextualTaskPrompt(rawObjective: task, userPrompt: task, goalSpec: boundGoalSpec)

        let steps: [LingShuRoleStep]
        if let fixedSteps { steps = fixedSteps } else { steps = await planRolePipeline(task: executionTask, agents: agents) }
        guard steps.count >= 2 else {
            // 没规划出多角色 → 清理这条预建记录/气泡,返回 false 让调用方回退 maker/checker(干净重来)。
            agentSubTaskRecords[subID] = nil
            dispatchedTaskBubbles[rid] = nil
            taskExecutionRecords.removeAll { $0.id == rid }; persistTaskExecutionRecords()
            if existingBubbleID == nil, let idx = chatMessages.firstIndex(where: { $0.id == bid }) { chatMessages.remove(at: idx) }
            else if let idx = chatMessages.firstIndex(where: { $0.id == bid }) { chatMessages[idx].taskRecordID = nil }
            return false
        }
        lastPipelineAgents = agents.map { LingShuRoleAgentRef(id: $0.id, name: $0.name) }   // 记下供续接继承
        lastPipelineTask = displayTask
        bindRolePipelineSlots(steps, recordID: rid)   // 结构化参与方:让 checker/maker 在任务窗口与 MCP 中稳定可见
        appendTaskRecordMessage(rid, actor: "灵枢", role: "派生子任务", kind: .router,
                                text: "派生角色管线子线程:" + steps.map { "\($0.roleTitle)(\($0.agentName ?? "灵枢"))" }.joined(separator: " → "))
        let intake = "🔧 已规划角色管线:" + steps.map { "\($0.roleTitle)(\($0.agentName ?? "灵枢"))" }.joined(separator: " → ")
        if let idx = chatMessages.firstIndex(where: { $0.id == bid }) { chatMessages[idx].text = intake }
        mirrorRolePipelinePlan(steps, recordID: rid)   // 把规划阶段镜像进 record.plan → 右侧「分步计划」看得到执行步骤
        let (result, passed) = await runRolePipeline(recordID: rid, task: executionTask, steps: steps)
        agentSubTaskRecords[subID] = nil
        let wasCancelled = cancelledPipelineRecords.contains(rid)   // 用户中途点了停止
        cancelledPipelineRecords.remove(rid)
        if let idx = chatMessages.firstIndex(where: { $0.id == bid }) {
            chatMessages[idx].text = intake + (wasCancelled ? "\n\n⏹ 已停止。"
                : (passed ? "\n\n✅ 管线完成,评审通过、已交付。\n" : "\n\n⚠️ 评审未通过,已交还(未交付,需修正后重验)。\n") + String(result.suffix(500)))
            chatMessages[idx].isLoading = false
        }
        if !wasCancelled {   // 被停止的已由 stopDispatchedTask 标 .failed,别再覆盖成 verified/needsRevision
            // **评审未通过用 .needsRevision(未达标),不要 .partial(部分完成)**:气泡明说"未交付、需修正后重验",
            // 而 .partial 显示"部分完成"=暗示有部分交付,与气泡矛盾(用户实测:内 部分完成 / 外 评审未通过已交还,不一致)。
            // .needsRevision 的"未达标"与气泡同义、且仍可被「继续」恢复返工(已加入 isResumableUnfinished)。
            finishTaskRecord(rid, status: passed ? .verified : .needsRevision,
                             summary: (passed ? "角色管线评审通过:" : "角色管线评审未通过(未达标·已交还、未交付):") + steps.map(\.roleTitle).joined(separator: "→"))
        }
        return true
    }

    /// **续接继承(用户定调:延续之前任务应沿用同样的 agent,不重置回灵枢)**:大脑判断这条新消息是不是上一个角色管线任务的延续。
    /// 非关键词——让大脑读懂「把刚才那个做完 / 运行起来验收 / 继续」这类延续意图。是→调用方用上次 agent 再跑管线。
    func isContinuationOfLastPipeline(prompt: String) async -> Bool {
        guard !lastPipelineAgents.isEmpty, !lastPipelineTask.isEmpty else { return false }
        let agentNames = lastPipelineAgents.map(\.name).joined(separator: "、")
        let system = LingShuPersona.identityLine + "\n" + """
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
        let system = LingShuPersona.identityLine + "\n" + """
        现在你来做这个任务的**角色规划**。下面是**当前可用的角色**和**可用的执行 agent**。请**语义判断**(别抠关键词):
        ① 这个任务需要**启用哪些角色**(用不到的别启用——简单代码任务可能只要 工程执行 + 评审官;复杂工程才上 项目经理/架构师);
        ② 每个启用的角色干**什么子任务**;③ 用**哪个 agent**执行(或灵枢自己)——这是可插孔的,同一角色可由任意 agent 担任。
        - **【最高优先级】先尊重用户的明确指派**:用户在请求里 @ 了某 agent 并说了它干什么——「用 @X 做 / 开发 / 写」→ 那个 agent 当**工程执行**;「@Y 验收 / 把关 / 审 / 复核」→ 那个 agent 当**评审官**。**必须按用户指定把那个 agent 分到那个角色,绝不擅自换成灵枢或别人。**
        - **别用灵枢架空用户指定的 agent**:用户已指派开发 agent(如 @Claude 做)时,**让那个 agent 直接承担设计+开发**——架构师这一环要么并给它(architect=同一个 agent)、要么干脆别启用,**绝不额外插一个「架构师=灵枢」在它前面替它干**(那会把用户指定的 agent 晾在后面、迟迟不参与)。只有用户**没**指派开发者时,才由你决定加哪些角色、可含灵枢。
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

    // MARK: - 把角色阶段镜像进 record.plan(右侧「分步计划」据此渲染)

    /// 计划步标题 = 角色 + 担任 agent(右侧步骤名;同时作为更新状态时的匹配键)。
    nonisolated static func rolePlanTitle(_ step: LingShuRoleStep) -> String {
        "\(step.roleTitle)（\(step.agentName ?? "灵枢")）"
    }

    /// 角色槽位 id = 角色 + agent + 序号。只做结构稳定性,不参与语义路由。
    nonisolated static func roleSlotID(_ step: LingShuRoleStep, index: Int) -> String {
        let raw = "\(index)-\(step.roleID)-\(step.agentID ?? step.agentName ?? "lingshu")"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return "role-" + raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    }

    nonisolated static func isReviewerRole(_ step: LingShuRoleStep, reviewerID: String, reviewerTitle: String) -> Bool {
        step.roleID == reviewerID || step.roleTitle == reviewerTitle
    }

    nonisolated static func roleSemantic(_ step: LingShuRoleStep, reviewerID: String, reviewerTitle: String) -> String {
        isReviewerRole(step, reviewerID: reviewerID, reviewerTitle: reviewerTitle) ? "checker" : "maker"
    }

    /// 规划完角色管线后,把各环镜像成 `record.plan` 的分步计划(pending)→ 右侧面板的「分步计划」就能显示**执行步骤**。
    /// (角色管线走确定性阶段、不经大脑 `update_plan`,以前只在左侧出参与方气泡、右侧没步骤——这里补上,与大脑驱动任务一致。)
    /// goal 传 nil:不覆盖已由 GoalSpec 蒸馏写入的一句话总目标。
    func mirrorRolePipelinePlan(_ steps: [LingShuRoleStep], recordID: String) {
        let planSteps = steps.map { LingShuPlanStep(title: Self.rolePlanTitle($0), status: .pending) }
        applyTaskPlan(planSteps, goal: nil, recordID: recordID)
    }

    /// 把模型规划出的角色管线绑定到任务记录的结构化槽位。
    /// UI/MCP/断点续跑都读 roleSlots,避免再从消息 actor 里猜参与方导致 checker 消失或 tab 数量漂移。
    func bindRolePipelineSlots(_ steps: [LingShuRoleStep], recordID: String) {
        guard let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let reviewer = expertProfileRegistry.reviewerProfile()
        let slots = steps.enumerated().map { index, step in
            LingShuTaskRoleSlot(
                id: Self.roleSlotID(step, index: index),
                roleID: step.roleID,
                roleTitle: step.roleTitle,
                agentID: step.agentID,
                agentName: step.agentName ?? "灵枢",
                semanticRole: Self.roleSemantic(step, reviewerID: reviewer.id, reviewerTitle: reviewer.title),
                status: .pending
            )
        }
        taskExecutionRecords[idx].roleSlots = slots
        for slot in slots where !taskExecutionRecords[idx].participants.contains(slot.agentName) {
            taskExecutionRecords[idx].participants.append(slot.agentName)
        }
        if taskExecutionRecords[idx].goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let objective = taskExecutionRecords[idx].goalSpec?.objective.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            taskExecutionRecords[idx].goal = objective.isEmpty ? taskExecutionRecords[idx].title : objective
        }
        taskExecutionRecords[idx].updatedAt = Date()
        persistTaskExecutionRecords()
    }

    /// 角色槽位状态推进。按 roleID + agent 双键更新,同一 agent 多角色时也不会串。
    func setRolePipelineSlotStatus(_ step: LingShuRoleStep, status: LingShuTaskRoleSlotStatus, recordID: String) {
        guard let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let agentName = step.agentName ?? "灵枢"
        guard let si = taskExecutionRecords[idx].roleSlots.firstIndex(where: {
            $0.roleID == step.roleID
                && ($0.agentID ?? "") == (step.agentID ?? "")
                && $0.agentName == agentName
        }) else { return }
        taskExecutionRecords[idx].roleSlots[si].status = status
        taskExecutionRecords[idx].updatedAt = Date()
        persistTaskExecutionRecords()
    }

    /// 逐环推进时更新对应计划步的状态(按标题匹配**首个未完成**的同名步,逐环打钩)。
    func setRolePipelinePlanStatus(_ step: LingShuRoleStep, status: LingShuPlanStep.Status, recordID: String) {
        guard let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let key = Self.rolePlanTitle(step)
        guard let si = taskExecutionRecords[idx].plan.firstIndex(where: { $0.title == key && $0.status != .completed }) else { return }
        taskExecutionRecords[idx].plan[si].status = status
        taskExecutionRecords[idx].updatedAt = Date()
        persistTaskExecutionRecords()
    }

    /// 按规划执行角色管线:**建设角色按序跑**(产出承接),然后**评审官把关**——评审官判不过→退回最后一个建设角色返工→
    /// 评审官再验,**通过才交付**(有界轮次)。每个角色作为**命名参与方**可见。返回(产出汇总, 是否通过)。
    func runRolePipeline(recordID rid: String, task: String, steps: [LingShuRoleStep], initialPrior: String = "") async -> (summary: String, passed: Bool) {
        let roles = expertProfileRegistry.allProfiles
        let reviewer = expertProfileRegistry.reviewerProfile()
        let builders = steps.filter { !Self.isReviewerRole($0, reviewerID: reviewer.id, reviewerTitle: reviewer.title) }       // 建设角色(架构/开发…)
        let reviewers = steps.filter { Self.isReviewerRole($0, reviewerID: reviewer.id, reviewerTitle: reviewer.title) }      // 评审官(可多个)
        var prior = initialPrior   // **续跑时**:上一轮的 maker 交付 + 评审意见作为承接上下文(别丢之前的进度/反馈)
        let goalCriteria = goalSpec(for: rid)?.acceptanceCriteriaBlock ?? ""   // 提炼出的逐条成功标准,注入每个角色(尤其评审官据此核验)
        appendTrace(kind: .route, actor: "角色规划", title: "多角色管线(\(steps.count) 环)",
                    detail: steps.map { "\($0.roleTitle)=\($0.agentName ?? "灵枢")" }.joined(separator: " → "))

        // 跑单个角色(agent 或灵枢会话),记参与方,返回产出。
        func runRole(_ step: LingShuRoleStep, tag: String, extra: String) async -> String {
            setRolePipelineSlotStatus(step, status: .running, recordID: rid)
            let rolePrompt = roles.first { $0.id == step.roleID }?.promptBlock ?? ""
            let objective = """
            你在本任务里担任角色:**\(step.roleTitle)**。
            \(rolePrompt)
            你这一环的子任务:\(step.subtask)
            \(goalCriteria.isEmpty ? "" : "本任务的成功标准(逐条对齐、别漏):\n\(goalCriteria)")
            \(extra)
            \(prior.isEmpty ? "" : "前序角色的产出(承接它往下做,别推翻重来):\n\(prior.prefix(2500))")
            产物落到当前工作目录;最后用一句话交代你这一环的结论 / 产出。
            """
            let actor = step.agentName ?? "灵枢"
            let startText = "▶ \(actor) 担任「\(step.roleTitle)」:\(step.subtask.prefix(80))"
            let output: String
            var roleSucceeded = true
            if let agentID = step.agentID, let plugin = LingShuAgentPluginStore.plugin(id: agentID) {
                // **流式**:边跑边把 agent 输出更新进同一条参与方气泡(不再干等)。
                switch await runAgentStreamingToRecord(plugin, objective: objective, recordID: rid,
                                                       actor: actor, role: "\(step.roleTitle)·\(tag)", startText: startText) {
                case .completed(let t): output = t
                case .failure(let f):
                    roleSucceeded = false
                    output = "(\(plugin.displayName) 未完成:\(f))"
                }
            } else {
                appendTaskRecordMessage(rid, actor: actor, role: "\(step.roleTitle)·\(tag)", kind: .agent, text: startText)
                let tools = agentBuiltinTools(recordIDProvider: { rid }, executionPolicy: dispatchedTaskExecutionPolicy)
                let session = makeAgentSession(id: "role-\(UUID().uuidString.prefix(6))", system: rolePrompt,
                                               tools: tools, model: makeAgentModelAdapter(), maxTurns: 40)
                output = LingShuStructuredModelOutput.visibleText(from: Self.runResultText(await session.send(objective)))
            }
            setRolePipelineSlotStatus(step, status: roleSucceeded ? .completed : .failed, recordID: rid)
            return output
        }

        // 1) 建设角色按序跑一遍。
        for (i, step) in builders.enumerated() {
            if Task.isCancelled || batchInterruptRequested || cancelledPipelineRecords.contains(rid) { break }
            setRolePipelinePlanStatus(step, status: .inProgress, recordID: rid)   // 右侧分步计划:本环进行中
            let o = await runRole(step, tag: "上岗(第\(i + 1)环)", extra: "")
            appendTaskRecordMessage(rid, actor: step.agentName ?? "灵枢", role: "\(step.roleTitle)·产出", kind: .result, text: String(o.prefix(1500)))
            prior += "\n【\(step.roleTitle)·\(step.agentName ?? "灵枢")】\n\(o.prefix(1500))"
            setRolePipelinePlanStatus(step, status: .completed, recordID: rid)    // 本环完成,打钩
        }
        // 没评审官 → 没把关,直接交付(大脑没规划评审就不强加)。
        guard !reviewers.isEmpty else { return (prior, true) }

        // 2) 评审官把关 → 不过退回最后一个建设角色返工 → 再验。**通过才交付,这是 LOOP 闭环。**
        // **无返工上限(2026-06-28 用户定调:不过就一直修,直到通过或手动中止;除此之外不该自己放弃)**——
        // 原来写死 maxRounds=2、超了就"已达返工上限、未交付",违反用户意图,改成无界:只在 通过 / 手动停止 / 模型通道故障暂停 时退出。
        var round = 0
        while true {
            if Task.isCancelled || batchInterruptRequested || cancelledPipelineRecords.contains(rid) {
                // **别一律说"已手动中止"**(用户实测:没中止却被这么标)。只有 `cancelledPipelineRecords`(用户点停止才
                // insert,见 TaskWindow:180)=真·手动中止;`Task.isCancelled`/`batchInterruptRequested` 可能是别的中断/泄漏,如实说。
                let userStopped = cancelledPipelineRecords.contains(rid)
                return (prior + (userStopped ? "\n\n(已手动中止,未交付。)"
                                             : "\n\n(执行被中断、未交付——不是你主动停的;可点「继续」重试。)"), false)
            }
            round += 1
            var fails: [String] = []
            for rev in reviewers {
                setRolePipelinePlanStatus(rev, status: .inProgress, recordID: rid)   // 右侧分步计划:评审进行中
                let v = await runRole(rev, tag: "验收(第\(round)轮)", extra: "你是把关方,独立核验前序产出是否达成目标(读代码/跑测试/运行)。\(LingShuCheckerVerdict.outputContract)")
                // 验收遇模型通道故障(超时/网络)≠ 验收驳回:产物已落地,暂停待重验,别误判需修正去返工。
                if let f = LingShuModelServiceFailure.decodeReason(v), f.shouldAutoResume {
                    appendTaskRecordMessage(rid, actor: rev.agentName ?? "灵枢", role: "\(rev.roleTitle)·验收暂停(模型通道故障)", kind: .warning,
                                            text: "验收时\(f.userFacingMessage)（产物已落地,非需修正;通道恢复后可重验)。")
                    return (prior + "\n\n(验收遇模型通道故障,产物已落地、待重验,未误判需修正。)", false)
                }
                let passed = Self.checkerVerdictPassed(v)
                appendTaskRecordMessage(rid, actor: rev.agentName ?? "灵枢",
                                        role: passed ? "\(rev.roleTitle)·通过" : "\(rev.roleTitle)·需修正(第\(round)轮)",
                                        kind: passed ? .result : .agent, text: String(v.prefix(1200)))
                if !passed { fails.append("【\(rev.roleTitle)】\(v.prefix(400))") }
                prior += "\n【\(rev.roleTitle)·\(passed ? "通过" : "需修正")】\n\(v.prefix(800))"
                setRolePipelinePlanStatus(rev, status: .completed, recordID: rid)   // 评审给出结论,本环打钩
            }
            if fails.isEmpty { return (prior, true) }                 // 全部评审通过 → 交付
            guard let producer = builders.last else {
                return (prior + "\n\n(评审未通过,但无可返工的建设角色,未交付。)", false)
            }
            // 退回最后一个建设角色返工(带评审意见)。无上限——一直修到过或手动停。
            let critique = fails.joined(separator: "\n")
            let fixed = await runRole(producer, tag: "返工(第\(round)轮)", extra: "**评审未通过,据下面意见返工修正(必须真改到能通过):**\n\(critique.prefix(1000))")
            appendTaskRecordMessage(rid, actor: producer.agentName ?? "灵枢", role: "\(producer.roleTitle)·返工交付(第\(round)轮)", kind: .result, text: String(fixed.prefix(1500)))
            prior += "\n【\(producer.roleTitle)·返工】\n\(fixed.prefix(1500))"
        }
    }
}
