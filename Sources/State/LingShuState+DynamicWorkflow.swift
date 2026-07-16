import Foundation

struct LingShuWorkflowNodeExecution: Sendable {
    var nodeID: String
    var sessionID: String
    var result: LingShuAgentRunResult
}

@MainActor
extension LingShuState {
    func workflowRun(id: String, recordID: String?) -> LingShuWorkflowRun? {
        guard let recordID,
              let record = taskExecutionRecords.first(where: { $0.id == recordID }) else { return nil }
        return record.workflowRuns.first(where: { $0.id == id })
    }

    func persistWorkflowRun(_ run: LingShuWorkflowRun, recordID: String?) {
        guard let recordID,
              let recordIndex = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        if let index = taskExecutionRecords[recordIndex].workflowRuns.firstIndex(where: { $0.id == run.id }) {
            taskExecutionRecords[recordIndex].workflowRuns[index] = run
        } else {
            taskExecutionRecords[recordIndex].workflowRuns.append(run)
        }
        persistTaskExecutionRecords()
    }

    func workflowMutationTool(recordID: String?, workflowID: String) -> LingShuAgentTool {
        let schema = """
        {"type":"object","properties":{"mutations":{"type":"array","items":{"type":"object","properties":{"operation":{"type":"string","enum":["add_node","replace_node","remove_node","replace_dependencies","retry_node","skip_node"]},"node":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"role":{"type":"string"},"objective":{"type":"string"},"dependencies":{"type":"array","items":{"type":"string"}}}},"node_id":{"type":"string"},"dependencies":{"type":"array","items":{"type":"string"}},"reason":{"type":"string"}},"required":["operation"]}}},"required":["mutations"]}
        """
        return LingShuAgentTool(
            name: "update_workflow",
            description: "当执行中发现原计划缺步骤、依赖顺序不合理或某节点需要重试/跳过时，提交受控的运行图变更。GoalSpec 和总目标不可修改；只能新增节点、替换尚未开始的节点、调整尚未开始节点的依赖、重试失败节点或跳过未运行节点。不要为普通进度更新调用。",
            parametersJSON: schema
        ) { [weak self] json in
            guard let self else { return "工作流运行时不可用。" }
            return await self.applyWorkflowMutations(json: json, workflowID: workflowID, recordID: recordID)
        }
    }

    func applyWorkflowMutations(json: String, workflowID: String, recordID: String?) -> String {
        guard var run = workflowRun(id: workflowID, recordID: recordID) else {
            return "当前工作流没有持久化上下文，不能在运行中改图；请按现有节点完成。"
        }
        guard let mutations = LingShuWorkflowMutation.parseList(json), !mutations.isEmpty else {
            return "工作流变更格式无效。"
        }
        if let rejection = workflowMutationRejection(mutations, run: run) { return rejection }
        do {
            try run.apply(mutations)
            persistWorkflowRun(run, recordID: recordID)
            appendTaskRecordMessage(recordID, actor: "工作流", role: "动态调整", kind: .router,
                                    text: "运行图已更新到 r\(run.revision)：\(mutations.map { $0.operation.rawValue }.joined(separator: "、"))")
            appendTrace(kind: .route, actor: "动态工作流", title: "运行图已调整",
                        detail: "workflow=\(workflowID.prefix(18)) revision=\(run.revision) mutations=\(mutations.count)")
            return "运行图变更已生效（revision \(run.revision)）。请继续当前节点。"
        } catch {
            return "工作流变更被拒绝：\(error)"
        }
    }

    private func workflowMutationRejection(_ mutations: [LingShuWorkflowMutation], run: LingShuWorkflowRun) -> String? {
        for mutation in mutations {
            switch mutation.operation {
            case .addNode:
                guard let node = mutation.node else { return "add_node 缺少完整 node。" }
                if run.nodes.contains(where: { $0.id == node.id }) { return "节点「\(node.id)」已存在。" }
            case .replaceNode, .removeNode, .replaceDependencies:
                let id = mutation.node?.id ?? mutation.nodeID ?? ""
                guard let node = run.nodes.first(where: { $0.id == id }) else { return "找不到节点「\(id)」。" }
                guard node.status == .pending else { return "节点「\(id)」已经开始，不能替换、删除或改依赖。" }
            case .retryNode:
                let id = mutation.nodeID ?? ""
                guard let node = run.nodes.first(where: { $0.id == id }) else { return "找不到节点「\(id)」。" }
                guard node.status == .failed || node.status == .skipped else { return "只有失败或已跳过节点可以重试。" }
            case .skipNode:
                let id = mutation.nodeID ?? ""
                guard let node = run.nodes.first(where: { $0.id == id }) else { return "找不到节点「\(id)」。" }
                guard node.status == .pending || node.status == .failed else { return "运行中、等待用户或已完成节点不能跳过。" }
            }
        }
        return nil
    }

    func driveWorkflowRun(
        _ initial: LingShuWorkflowRun,
        recordID: String?,
        model: any LingShuAgentModel
    ) async -> LingShuWorkflowRun {
        var run = initial
        while !Task.isCancelled {
            if let persisted = workflowRun(id: run.id, recordID: recordID) { run = persisted }
            run.reconcileStatus()
            if run.status != .running { return run }

            let capacity = await agentOrchestrator.availableCapacity()
            if capacity == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let ready = Array(run.readyNodes.prefix(capacity))
            guard !ready.isEmpty else {
                if run.nodes.isEmpty || !run.nodes.contains(where: { $0.status == .running }) {
                    run.status = .failed
                    run.updatedAt = Date()
                    persistWorkflowRun(run, recordID: recordID)
                }
                return run
            }

            for node in ready { run.updateNode(node.id, status: .running) }
            persistWorkflowRun(run, recordID: recordID)

            var tasks: [Task<LingShuWorkflowNodeExecution, Never>] = []
            for node in ready {
                let context = node.dependencies.compactMap { dependency in
                    run.nodes.first(where: { $0.id == dependency })?.output.map {
                        "【「\(dependency)」的产出】\n\(String($0.prefix(1_500)))"
                    }
                }.joined(separator: "\n\n")
                tasks.append(Task { @MainActor [weak self] in
                    guard let self else {
                        return .init(nodeID: node.id, sessionID: "", result: .interrupted(reason: "工作流运行时已释放"))
                    }
                    return await self.runWorkflowNode(node, context: context, workflowID: run.id, recordID: recordID, model: model)
                })
            }

            var results: [LingShuWorkflowNodeExecution] = []
            results.reserveCapacity(tasks.count)
            for task in tasks { results.append(await task.value) }
            if let persisted = workflowRun(id: run.id, recordID: recordID) { run = persisted }
            for execution in results {
                applyWorkflowNodeResult(execution, to: &run)
            }
            persistWorkflowRun(run, recordID: recordID)
        }
        return run
    }

    private func runWorkflowNode(
        _ node: LingShuWorkflowNode,
        context: String,
        workflowID: String,
        recordID: String?,
        model: any LingShuAgentModel
    ) async -> LingShuWorkflowNodeExecution {
        let sessionID = "role-\(UUID().uuidString.prefix(5))-\(node.name.prefix(10))"
        let system = """
        你是动态协作工作流里的命名角色「\(node.name)」（职责：\(node.role)）。只完成当前节点目标，不改写总目标。
        执行中若发现缺少必要步骤或依赖不合理，用 update_workflow 提交受控改图；不要只在文字里建议改流程。
        任何阶段若确实需要用户扫码、登录、操作实体设备、选文件、确认或补充信息，在最终结构化输出的 human_interaction 中声明；这不是失败，也不要让验收器把它写成“不通过”。
        有产出物必须真落盘并给绝对路径；代码必须构建、运行、测试通过。完成后清晰交付本节点产出。
        """
        let input = context.isEmpty ? node.objective
            : "你的节点目标：\(node.objective)\n\n已完成依赖节点的产出：\n\(context)"
        let tools = agentBuiltinTools(recordIDProvider: { recordID })
            + [Self.timeTool(), Self.locationTool(), webSearchTool(), searchTextTool(), findImagesTool(), Self.askUserTool(),
               workflowMutationTool(recordID: recordID, workflowID: workflowID)]
        let session = makeAgentSession(
            id: sessionID,
            system: system,
            tools: tools,
            model: model,
            maxTurns: 80,
            recordIDProvider: { recordID }
        )
        appendTaskRecordMessage(recordID, actor: node.name, role: "角色·\(node.role)", kind: .agent,
                                text: "角色「\(node.name)」开始：\(node.objective)\(context.isEmpty ? "" : "（已接前序产出）")")
        let result = await agentOrchestrator.spawn(id: sessionID, objective: input, session: session)
        let visible = LingShuStructuredModelOutput.visibleText(from: Self.runResultText(result))
        appendTaskRecordMessage(
            recordID,
            actor: node.name,
            role: result.isHumanBlocked ? "角色·\(node.role)·等待协作" : "角色·\(node.role)·产出",
            kind: result.isHumanBlocked ? .warning : .result,
            text: String(visible.prefix(600))
        )
        return .init(nodeID: node.id, sessionID: sessionID, result: result)
    }

    private func applyWorkflowNodeResult(_ execution: LingShuWorkflowNodeExecution, to run: inout LingShuWorkflowRun) {
        guard let node = run.nodes.first(where: { $0.id == execution.nodeID }) else { return }
        switch execution.result {
        case .completed(let text):
            run.updateNode(node.id, status: .completed,
                           output: LingShuStructuredModelOutput.visibleText(from: text), sessionID: execution.sessionID)
        case .blocked(let question):
            let request = workflowHumanInteractionRequest(
                from: question,
                workflowID: run.id,
                node: node,
                sessionID: execution.sessionID
            )
            run.updateNode(node.id, status: .waitingForHuman, humanInteraction: request, sessionID: execution.sessionID)
        case .maxTurnsReached(let text):
            if LingShuStructuredModelOutput.parse(text)?.completion?.status == .ok {
                run.updateNode(node.id, status: .completed,
                               output: LingShuStructuredModelOutput.visibleText(from: text), sessionID: execution.sessionID)
            } else {
                run.updateNode(node.id, status: .failed, failureReason: "节点达到轮次上限仍未完成", sessionID: execution.sessionID)
            }
        case .interrupted(let reason):
            run.updateNode(node.id, status: .failed,
                           failureReason: LingShuModelServiceFailure.suspendedSummary(for: reason), sessionID: execution.sessionID)
        }
    }

    private func workflowHumanInteractionRequest(
        from question: String,
        workflowID: String,
        node: LingShuWorkflowNode,
        sessionID: String
    ) -> LingShuHumanInteractionRequest {
        var request = LingShuWorkflowControlEnvelope.extract(from: question)?.humanInteraction
            ?? Self.legacyHumanInteractionRequest(from: question)
            ?? .init(kind: .question, title: "需要你参与", prompt: LingShuHumanInputEnvelope.userFacingText(from: question))
        if let previous = request.resumeToken, !previous.isEmpty { request.payload["upstream_resume_token"] = previous }
        request.resumeToken = LingShuWorkflowResumeToken(workflowID: workflowID, nodeID: node.id, sessionID: sessionID).encoded
        request.source = node.name
        return request.normalized ?? .init(kind: .question, title: "需要你参与", prompt: "这一步需要你参与后才能继续。")
    }

    nonisolated private static func legacyHumanInteractionRequest(from question: String) -> LingShuHumanInteractionRequest? {
        guard let envelope = LingShuHumanInputEnvelope.firstEmbedded(in: question)?.envelope
                ?? LingShuHumanInputEnvelope.decode(from: question),
              let data = envelope.argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let prompt = (["question", "prompt", "message", "title"].compactMap { args[$0] as? String }.first)
            ?? LingShuHumanInputEnvelope.userFacingText(for: envelope)
        switch envelope.tool {
        case "ask_choice":
            let options = ((args["options"] as? [Any]) ?? []).compactMap { value -> LingShuHumanInteractionRequest.Option? in
                if let label = value as? String { return .init(label: label) }
                guard let option = value as? [String: Any], let label = option["label"] as? String else { return nil }
                return .init(label: label, detail: (option["detail"] as? String) ?? "", value: option["value"] as? String)
            }
            return .init(kind: .choice, title: (args["title"] as? String) ?? prompt, prompt: prompt, options: options)
        case "ask_form":
            return .init(kind: .form, title: (args["title"] as? String) ?? prompt, prompt: prompt,
                         payload: ["form_json": envelope.argumentsJSON])
        default:
            return .init(kind: .question, title: (args["title"] as? String) ?? prompt, prompt: prompt)
        }
    }

    func resumeWorkflowInteraction(
        _ request: LingShuHumanInteractionRequest,
        recordID: String?,
        answer: String
    ) async -> String? {
        guard let token = LingShuWorkflowResumeToken.decode(request.resumeToken),
              var run = workflowRun(id: token.workflowID, recordID: recordID),
              let nodeIndex = run.nodes.firstIndex(where: { $0.id == token.nodeID }) else { return nil }
        let resumeInput = "【人机协作已完成】\n类型：\(request.kind.rawValue)\n结果：\(answer)\n请从暂停点继续当前节点，不要重新开始。"

        if let result = await agentOrchestrator.resume(id: token.sessionID, answer: resumeInput) {
            applyWorkflowNodeResult(.init(nodeID: token.nodeID, sessionID: token.sessionID, result: result), to: &run)
        } else {
            // App 重启后会话内存不在，但运行图仍在。复用同一节点并把人工结果作为恢复上下文，
            // 不新建目标、不丢已完成依赖，也不把整条任务从头再跑。
            run.nodes[nodeIndex].status = .pending
            run.nodes[nodeIndex].humanInteraction = nil
            run.nodes[nodeIndex].sessionID = nil
            run.nodes[nodeIndex].objective += "\n\n恢复信息：此前要求的人机协作已完成，用户结果为「\(answer)」。从当前节点继续。"
            run.nodes[nodeIndex].updatedAt = Date()
            run.reconcileStatus()
        }
        persistWorkflowRun(run, recordID: recordID)
        run = await driveWorkflowRun(run, recordID: recordID, model: makeAgentModelAdapter())
        return workflowResultText(run)
    }

    func workflowResultText(_ run: LingShuWorkflowRun) -> String {
        if let interaction = run.waitingInteraction {
            return LingShuWorkflowControlEnvelope(event: .requiresHumanInteraction(interaction)).encodedPrompt
        }
        if run.status == .completed {
            let body = run.nodes.map { node in
                "【\(node.name)·\(node.role)】\((node.output ?? "").isEmpty ? "（无文字产出）" : String((node.output ?? "").prefix(700)))"
            }.joined(separator: "\n\n")
            return "命名角色团队（\(run.nodes.count) 个角色按动态依赖协作完成）：\n\n\(body)"
        }
        let failed = run.nodes.filter { $0.status == .failed }
            .map { "\($0.name)：\($0.failureReason ?? "未完成")" }
            .joined(separator: "；")
        return "动态工作流未能完成：\(failed.isEmpty ? "当前没有可运行节点" : failed)"
    }
}

private extension LingShuAgentRunResult {
    var isHumanBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}
