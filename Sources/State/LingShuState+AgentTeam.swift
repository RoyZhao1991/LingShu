import Foundation

/// 差距6·**命名角色 spawn + DAG**:同一件事拆给若干**命名角色 agent**(研究员/执行/审查… 名字+职责由大脑给,壳零硬编码),
/// 角色间声明**依赖** → 按拓扑 DAG 分层调度(纯逻辑 `LingShuAgentDAG`):层内并行、层间按序,前序角色产出作为后续角色上下文,
/// 最后聚合。**可见**:每个命名角色在任务时间线出卡(开始/产出),独立审查官也已是命名「审查员」卡(见 AgentAcceptance)。
/// 对标 Codex 的"一个任务里多个命名角色协作 + 独立 checker"。复用编排器 `spawn`(隔离会话 + 账本 + 并发上限)。
@MainActor
extension LingShuState {

    private static let teamSchema = """
    {"type":"object","properties":{"agents":{"type":"array","description":"命名角色列表;每项 {name:角色名, role:职责一词, objective:该角色要达成的目标, depends_on:依赖的角色名数组(无依赖给[])}。系统按依赖 DAG 调度:无依赖的并行先跑,依赖者拿到前序角色产出再跑。用于一件事需要'研究→实现→审查'这类有先后/分工的协作。","items":{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"objective":{"type":"string"},"depends_on":{"type":"array","items":{"type":"string"}}},"required":["name","objective"]}}},"required":["agents"]}
    """

    /// spawn_team 工具:把需要多角色协作的一件事拆给命名角色团队,按依赖 DAG 调度。
    /// 与 spawn_task 区别:spawn_task 派**互不相关的并行任务**;spawn_team 派**同一件事里有分工/先后依赖的角色**。
    func spawnTeamTool(recordIDProvider: @escaping @MainActor @Sendable () -> String?, model: any LingShuAgentModel) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "spawn_team",
            description: "把一件**需要多个不同角色协作**的任务,拆给若干**命名角色 agent**(你给每个起名+定职责+目标,并声明依赖)。系统按依赖 DAG 调度:无依赖的并行先跑,依赖者拿到前序角色产出再跑,最后聚合;每个角色在任务时间线可见。用于'研究→实现→审查'这类有先后/分工的协作。**互不相关的并行目标用 spawn_task。**",
            parametersJSON: Self.teamSchema
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            return await self.runAgentTeam(argsJSON: argsJSON, recordID: recordIDProvider(), model: model)
        }
    }

    /// 执行命名角色团队：声明只负责给出初始图；运行时图会持久化，并允许角色用受控 mutation 动态调整。
    func runAgentTeam(argsJSON: String, recordID: String?, model: any LingShuAgentModel) async -> String {
        if isMinimalVoiceMode { return "当前是极简对话模式(纯对话),不派生角色团队。请直接简洁作答。" }
        guard let specs = LingShuAgentDAG.parse(argsJSON), !specs.isEmpty else {
            return "spawn_team 参数无效:需要 {\"agents\":[{\"name\":\"角色名\",\"role\":\"职责\",\"objective\":\"目标\",\"depends_on\":[]}]}。"
        }
        let layers: [[LingShuRoleAgentSpec]]
        switch LingShuAgentDAG.topologicalLayers(specs) {
        case .failure(let f):
            return "spawn_team 无法调度:\(f)。请修正角色依赖(去环/补齐被依赖的角色)后重试。"
        case .success(let l):
            layers = l
        }
        let plan = layers.enumerated().map { "第\($0.offset + 1)层[\($0.element.map(\.name).joined(separator: "、"))]" }.joined(separator: " → ")
        appendTrace(kind: .system, actor: "编排", title: "组建命名角色团队",
                    detail: "\(specs.count) 个初始角色,\(layers.count) 层:\(plan)。执行中允许受控改图。")

        let goal = recordID.flatMap { id in
            taskExecutionRecords.first(where: { $0.id == id }).map { record in
                record.goalSpec?.objective ?? (record.goal.isEmpty ? record.prompt : record.goal)
            }
        } ?? "完成命名角色团队任务"
        let nodes = specs.map {
            LingShuWorkflowNode(id: $0.name, name: $0.name, role: $0.role,
                                objective: $0.objective, dependencies: $0.dependsOn)
        }
        var run = LingShuWorkflowRun(taskRecordID: recordID, goal: goal, nodes: nodes)
        do {
            try run.validate()
        } catch {
            return "spawn_team 无法调度:\(error)"
        }
        persistWorkflowRun(run, recordID: recordID)
        appendTaskRecordMessage(recordID, actor: "工作流", role: "运行图", kind: .router,
                                text: "已建立可动态调整的运行图：\(specs.count) 个节点，revision 1。")
        run = await driveWorkflowRun(run, recordID: recordID, model: model)
        return workflowResultText(run)
    }

    /// 聚合各命名角色产出成一句面向主人的团队交付(按角色列出,纯逻辑)。
    func aggregateTeamResult(specs: [LingShuRoleAgentSpec], outputs: [String: String]) -> String {
        let body = specs.map { spec -> String in
            let out = (outputs[spec.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "【\(spec.name)·\(spec.role)】\(out.isEmpty ? "(无产出)" : String(out.prefix(500)))"
        }.joined(separator: "\n\n")
        return "命名角色团队(\(specs.count) 个角色按依赖协作完成):\n\n\(body)"
    }
}
