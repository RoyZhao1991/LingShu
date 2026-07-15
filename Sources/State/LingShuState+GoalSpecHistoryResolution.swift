import Foundation

/// Active Turn 的低置信引用归属：让当前大脑检索完整历史后重新提交 GoalSpec。
/// 行为只按网关协议和真实能力响应协商，不按 provider/model 名称定制。
@MainActor
extension LingShuState {
    func deriveGoalSpecWithHistoryFallback(
        for request: String,
        initialSpec: LingShuGoalSpec,
        taskRecordID: String?,
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) async -> (spec: LingShuGoalSpec, supportLines: [String])? {
        let supportBox = LingShuGoalSpecHistorySupportBox()
        let basePrompt = activeTurnGoalSpecHistoryFallbackRequest(for: request, initialSpec: initialSpec)
        let timeouts = LingShuGoalSpecGenerationPolicy.timeouts(
            for: LingShuGoalSpecParser.systemPrompt + "\n" + basePrompt
        )
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let requestFormat = LingShuModelGateway().requestFormat(
            provider: modelProvider,
            endpoint: endpoint,
            protocolName: protocolName
        )
        var preferToolSearch = LingShuStructuredGoalSpecCapability.shouldAttemptToolSubmission(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: protocolName,
            format: requestFormat
        )
        var prefetchedHistory: LingShuGoalSpecHistorySearchResult?
        var lastIssue = "历史检索未完成"

        for (offset, timeout) in timeouts.enumerated() {
            guard !Task.isCancelled else { return nil }
            let attempt = offset + 1
            let total = timeouts.count
            let useToolSearch = preferToolSearch
            onProgress?(
                attempt,
                total,
                useToolSearch
                    ? "目标引用不确定,当前大脑正在检索历史(\(attempt)/\(total))…"
                    : "目标引用不确定,正在基于已取回历史重新生成(\(attempt)/\(total))…"
            )

            if !useToolSearch, prefetchedHistory == nil {
                prefetchedHistory = goalSpecHistorySearchPayload(
                    query: "\(request) \(initialSpec.objective)",
                    scope: "all",
                    excludingCurrentRawPrompt: request,
                    limit: 12
                )
            }
            let prompt = useToolSearch
                ? basePrompt
                : goalSpecHistoryPrefetchedRequest(
                    basePrompt: basePrompt,
                    retrievedHistory: prefetchedHistory?.text ?? "历史检索没有返回候选。"
                )
            let transportInstruction = useToolSearch
                ? "必须先调用 search_goal_history，再调用 submit_goal_spec 提交最终 GoalSpec。"
                : "retrieved_history_context 已由宿主检索并放进请求；基于它严格只输出一个 GoalSpec JSON。"
            let system = LingShuGoalSpecParser.systemPrompt + """

            历史归属模式:
            - \(transportInstruction)
            - 历史候选只提供证据,最终目标必须由你结合 current_user_input 判断。
            - 找到对象后,objective/success_criteria 必须保留具体实体；找不到就把 reference_confidence 设为 "low" 并写 open_questions,不要编造。
            """
            let adapter = controlPlaneModelAdapter(
                .goalSpec,
                taskRecordID: taskRecordID,
                timeoutOverride: timeout
            )
            let submissionBox = LingShuGoalSpecSubmissionBox(allowUnresolvedReference: false)
            let tools: [LingShuAgentTool] = useToolSearch
                ? [
                    goalSpecHistorySearchTool(excludingCurrentRawPrompt: request, supportBox: supportBox),
                    LingShuGoalSpecToolContract.makeTool(box: submissionBox)
                ]
                : []
            let session = LingShuAgentSession(
                id: "goalspec-history-\(UUID().uuidString.prefix(6))",
                system: system,
                tools: tools,
                model: adapter,
                maxTurns: 4
            )
            let result = await session.send(prompt)
            guard !Task.isCancelled else { return nil }
            let invocations = await session.toolInvocations
            let submission = await submissionBox.snapshot()

            if let submitted = submission.accepted {
                guard !useToolSearch || invocations.contains("search_goal_history") else {
                    lastIssue = "模型提交 GoalSpec 前未调用 search_goal_history"
                    preferToolSearch = false
                    appendTrace(
                        kind: .warning,
                        actor: "目标认知",
                        title: "历史工具未调用",
                        detail: "通道没有被标记为不支持；本轮改由宿主取回相同历史证据，再交当前大脑生成。"
                    )
                    continue
                }
                if submitted.referenceConfidence == .high {
                    let supportLines = (await supportBox.snapshot()) + (prefetchedHistory?.supportLines ?? [])
                    appendTrace(
                        kind: .system,
                        actor: "目标认知",
                        title: "GoalSpec 历史归属",
                        detail: "首轮引用置信度=\(initialSpec.referenceConfidence.rawValue), scope=\(initialSpec.referenceScope.rawValue); 第 \(attempt)/\(total) 次完成; 模式=\(useToolSearch ? "模型工具检索" : "宿主取证后模型判断"); 兜底结果=\(submitted.summary)"
                    )
                    return (submitted, supportLines)
                }
                lastIssue = "历史检索后引用置信度仍为 \(submitted.referenceConfidence.rawValue)"
            }

            switch result {
            case .completed(let text):
                guard !useToolSearch || invocations.contains("search_goal_history") else {
                    lastIssue = "模型未调用 search_goal_history"
                    preferToolSearch = false
                    break
                }
                guard let spec = LingShuGoalSpecParser.parse(LingShuReasoningText.stripThinkTags(text)) else {
                    lastIssue = "模型未产出可解析 GoalSpec JSON"
                    break
                }
                if let issue = LingShuGoalSpecParser.executionReadinessIssue(spec) {
                    lastIssue = issue
                    break
                }
                guard spec.referenceConfidence == .high else {
                    lastIssue = "历史检索后引用置信度仍为 \(spec.referenceConfidence.rawValue)"
                    break
                }
                let supportLines = (await supportBox.snapshot()) + (prefetchedHistory?.supportLines ?? [])
                appendTrace(
                    kind: .system,
                    actor: "目标认知",
                    title: "GoalSpec 历史兜底",
                    detail: "首轮引用置信度=\(initialSpec.referenceConfidence.rawValue), scope=\(initialSpec.referenceScope.rawValue); 第 \(attempt)/\(total) 次完成; 模式=\(useToolSearch ? "模型工具检索" : "宿主取证后模型判断"); 工具调用=\(invocations.joined(separator: ",")); 兜底结果=\(spec.summary)"
                )
                return (spec, supportLines)
            case .interrupted(let reason):
                lastIssue = "模型调用中断:\(String(reason.prefix(180)))"
                if useToolSearch,
                   LingShuStructuredGoalSpecCapability.explicitlyRejectsToolSubmission(reason) {
                    LingShuStructuredGoalSpecCapability.markToolSubmissionUnsupported(
                        provider: modelProvider,
                        model: modelName,
                        endpoint: endpoint,
                        protocolName: protocolName
                    )
                    preferToolSearch = false
                    lastIssue = "当前通道明确拒绝工具协议；下一次由宿主取回历史证据后交同一大脑判断"
                } else if useToolSearch,
                          LingShuModelServiceFailure.decodeReason(reason)?.kind == .requestInvalid {
                    preferToolSearch = false
                }
            case .blocked(let question):
                lastIssue = "历史归属意外进入等待:\(String(question.prefix(180)))"
            case .maxTurnsReached(let lastText):
                lastIssue = "历史归属达到回合上限:\(String(lastText.prefix(180)))"
            }
            appendTrace(
                kind: .system,
                actor: "目标认知",
                title: attempt < total ? "GoalSpec 历史兜底未完成·准备重试" : "GoalSpec 历史兜底未完成",
                detail: "第 \(attempt)/\(total) 次(timeout=\(Int(timeout))s):\(lastIssue)"
            )
        }
        appendTrace(
            kind: .system,
            actor: "目标认知",
            title: "GoalSpec 历史兜底耗尽",
            detail: "已尝试 \(timeouts.count) 次,最后原因:\(lastIssue)。"
        )
        return nil
    }

    private func activeTurnGoalSpecHistoryFallbackRequest(
        for request: String,
        initialSpec: LingShuGoalSpec
    ) -> String {
        var payload = activeTurnGoalSpecContextPayload(for: request) ?? [
            "type": "lingshu_active_turn_goal_context",
            "current_user_input": request
        ]
        payload["type"] = "lingshu_active_turn_goal_context_history_fallback"
        payload["initial_goal_spec"] = [
            "summary": initialSpec.summary,
            "reference_scope": initialSpec.referenceScope.rawValue,
            "reference_confidence": initialSpec.referenceConfidence.rawValue,
            "reference_evidence": initialSpec.referenceEvidence
        ]
        payload["history_fallback_rules"] = [
            "You are in history fallback mode because the first GoalSpec did not provide a high-confidence referenced target.",
            "If search_goal_history is available, call it at least once with the best query you can infer. If it is not available, read retrieved_history_context supplied by the host.",
            "If a tool search is too broad or misses the target, call it again with a different query or broader scope.",
            "After reading retrieved history, submit one GoalSpec through submit_goal_spec when available; otherwise return one GoalSpec JSON. Set reference_confidence high only when concrete evidence supports the selected target.",
            "If no reliable target is found, return a low-confidence GoalSpec with open_questions instead of inventing the target."
        ]
        return serializedGoalSpecPayload(payload, fallbackText: request)
    }

    private func goalSpecHistoryPrefetchedRequest(basePrompt: String, retrievedHistory: String) -> String {
        var payload = (basePrompt.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [
                "type": "lingshu_active_turn_goal_context_history_fallback",
                "original_context": basePrompt
            ]
        if let data = retrievedHistory.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["retrieved_history_context"] = object
        } else {
            payload["retrieved_history_context"] = retrievedHistory
        }
        payload["history_transport"] = "host_prefetched_for_model_judgement"
        return serializedGoalSpecPayload(payload, fallbackText: basePrompt)
    }

    private func goalSpecHistorySearchTool(
        excludingCurrentRawPrompt rawPrompt: String,
        supportBox: LingShuGoalSpecHistorySupportBox
    ) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "search_goal_history",
            description: "检索用于 GoalSpec 引用归属的历史记录。可返回热/冷对话、任务记录、主线程记忆和关键词命中；当 current_user_input 出现弱指代时用它找被引用对象。",
            parametersJSON: """
            {"type":"object","properties":{
            "query":{"type":"string","description":"要检索的历史线索。可以是当前用户输入,也可以是你从上下文推断出的主题/实体/任务名。"},
            "scope":{"type":"string","enum":["all","recent","chat","task","memory"],"description":"检索范围,默认 all。"},
            "limit":{"type":"number","description":"每类最多返回多少候选,默认 8,最大 24。"}
            },"required":["query"]}
            """
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            let query = (Self.jsonField(argsJSON, "query") ?? rawPrompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let scope = (Self.jsonField(argsJSON, "scope") ?? "all")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawLimit = Int(Self.jsonNumber(argsJSON, "limit") ?? 8)
            let limit = max(3, min(24, rawLimit))
            let result = await MainActor.run {
                self.goalSpecHistorySearchPayload(
                    query: query.isEmpty ? rawPrompt : query,
                    scope: scope,
                    excludingCurrentRawPrompt: rawPrompt,
                    limit: limit
                )
            }
            await supportBox.append(result.supportLines)
            return result.text
        }
    }
}
