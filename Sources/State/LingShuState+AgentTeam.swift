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

    /// 执行命名角色团队:解析 → 拓扑分层 → 逐层(层内并行)起隔离会话经 orchestrator.spawn 跑到收尾、传依赖产出 → 聚合。
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
                    detail: "\(specs.count) 个角色,\(layers.count) 层(层内并行、层间按序):\(plan)")

        var outputs: [String: String] = [:]   // 角色名 → 产出文本(供后续层作上下文)
        for layer in layers {
            // 层内并行:每个角色起一个非结构化 Task(立即并发跑,网络往返重叠),本层全收齐再进下一层。
            var layerTasks: [(name: String, task: Task<String, Never>)] = []
            for spec in layer {
                let s = spec
                let context = spec.dependsOn
                    .compactMap { d in outputs[d].map { "【「\(d)」的产出】\n\($0.prefix(1200))" } }
                    .joined(separator: "\n\n")
                let task = Task { @MainActor [weak self] () -> String in
                    guard let self else { return "" }
                    return await self.runRoleAgent(spec: s, context: context, recordID: recordID, model: model)
                }
                layerTasks.append((s.name, task))
            }
            for entry in layerTasks { outputs[entry.name] = await entry.task.value }
        }
        return aggregateTeamResult(specs: specs, outputs: outputs)
    }

    /// 跑一个命名角色:起隔离会话(全工具 + 角色系统提示 + 依赖上下文)经 orchestrator.spawn 到收尾;时间线出**命名角色卡**。
    private func runRoleAgent(spec: LingShuRoleAgentSpec, context: String, recordID: String?, model: any LingShuAgentModel) async -> String {
        let id = "role-\(UUID().uuidString.prefix(5))-\(spec.name.prefix(10))"
        let system = """
        你是一个协作团队里的命名角色「\(spec.name)」(职责:\(spec.role))。**只做你这个角色该做的事**,别越界替别的角色做。
        做完用清晰的一段交付你的产出(会作为后续角色的输入/最终汇总)。有产出物就用 write_file/run_command 真落盘并给绝对路径;
        写代码要真构建+运行起来+测试全绿、把真实结果展示出来;信息确实不足才 ask_user。
        """
        let input = context.isEmpty ? spec.objective
            : "你的目标:\(spec.objective)\n\n前序角色已完成(作为你的输入/上下文):\n\(context)"
        let tools = agentBuiltinTools(recordIDProvider: { recordID })
            + [Self.timeTool(), Self.locationTool(), webSearchTool(), searchTextTool(), findImagesTool(), Self.askUserTool()]
        let session = makeAgentSession(id: id, system: system, tools: tools, model: model, maxTurns: 80, recordIDProvider: { recordID })

        appendTaskRecordMessage(recordID, actor: spec.name, role: "角色·\(spec.role)", kind: .agent,
                                text: "🧑‍💼 角色「\(spec.name)」(\(spec.role))开始:\(spec.objective)\(context.isEmpty ? "" : "(已接前序产出)")")
        let result = await agentOrchestrator.spawn(id: id, objective: input, session: session)
        let text = LingShuStructuredModelOutput.visibleText(from: Self.runResultText(result))
        appendTaskRecordMessage(recordID, actor: spec.name, role: "角色·\(spec.role)·完成", kind: .result,
                                text: "🧑‍💼 角色「\(spec.name)」产出:\(String(text.prefix(400)))")
        return text
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
