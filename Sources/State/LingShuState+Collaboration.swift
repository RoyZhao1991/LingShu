import Foundation

/// 协同管线：把"每个 agent 说一句固定台词"的剧场，换成真实的多轮专家协作——
/// 规划（项目经理）→ 草稿（按任务匹配的专家 + 模板 + 知识要点）→ 评审（评审官逐条核对）
/// → 纠正（按意见修订）→ 验收（最终结论 + 下一步建议）。每一步都是真实模型调用，
/// 全程进任务执行记录；任务上下文与聊天完全隔离，同任务多次迭代继承前序结论。
@MainActor
extension LingShuState {
    var hasRunningCollaborationPipeline: Bool {
        activePipelineToken != nil
    }

    /// 管线入口：先做资源准入评定，不适合立刻执行就排队并告知用户。
    func startCollaborationPipeline(for userPrompt: String, route: CodexRoutePayload, taskRecordID: String?) {
        let sample = LingShuSystemLoadProbe.currentSample(activePipelines: hasRunningCollaborationPipeline ? 1 : 0)
        let verdict = LingShuTaskAdmissionPolicy.evaluate(sample)
        appendTaskRecordMessage(taskRecordID, actor: "调度", role: "资源准入", kind: .router, text: verdict.reason)
        appendTrace(
            kind: .runtime,
            actor: "调度",
            title: verdict.decision == .proceed ? "准入通过" : "进入队列",
            detail: verdict.reason
        )

        guard verdict.decision == .proceed else {
            let threadID = activeTaskThread?.id ?? taskRuntime.taskID
            enqueueTaskSegment(
                threadID: threadID,
                fingerprint: LingShuTaskThreadScheduler.fingerprint(for: userPrompt, restoredTaskID: threadID),
                prompt: userPrompt,
                recordID: taskRecordID,
                reason: verdict.reason
            )
            chatMessages.append(.init(
                speaker: "灵枢",
                text: "这个任务我先放进队列：\(verdict.reason)",
                isUser: false,
                taskRecordID: taskRecordID
            ))
            return
        }

        runCollaborationPipeline(for: userPrompt, route: route, taskRecordID: taskRecordID)
    }

    private func runCollaborationPipeline(for userPrompt: String, route: CodexRoutePayload, taskRecordID: String?) {
        isModelExecuting = true
        enterCoreState(.executing)
        markTaskRuntimeExecuting(route, for: userPrompt)

        let channel = PipelineChannel(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: selectedModelPreset?.protocolName ?? "OpenAI 兼容",
            apiKey: apiKey,
            temperature: temperature,
            timeout: codexTimeoutSeconds,
            useStreaming: shouldUseLocalStreamingDialogue
        )
        let expert = expertProfileRegistry.profile(for: userPrompt + " " + route.agents.map(\.task).joined(separator: " "))
        let reviewer = expertProfileRegistry.reviewerProfile()
        let threadID = activeTaskThread?.id
        let inherited = taskIterationContext(threadID: threadID, currentRecordID: taskRecordID)
        let pipelineToken = UUID()
        activePipelineToken = pipelineToken

        if !inherited.isEmpty {
            appendTaskRecordMessage(taskRecordID, actor: "记忆", role: "执行记忆", kind: .memory, text: "本段继承同任务前序迭代的结论，专家产出会在其基础上延续。")
        }
        appendTaskRecordMessage(
            taskRecordID,
            actor: "调度",
            role: "任务编排",
            kind: .agent,
            text: "协同管线启动：\(expert.title) 主笔，评审官全程核对，过程不合格会被打回修正。"
        )

        // 草稿阶段的流式气泡：专家产出逐字上屏。
        let pending = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true, taskRecordID: taskRecordID)
        chatMessages.append(pending)
        let bubbleID = pending.id

        executionPipelineTask = Task { [weak self] in
            guard let self else { return }
            var probe = LingShuStreamLatencyProbe()
            var draft = ""
            do {
                // ① 规划：项目经理给执行计划 + 验收标准。
                self.missionTitle = "规划中"
                self.missionStatus = "项目经理专家正在拆解任务并定验收标准。"
                let planPrompt = """
                为下面的任务制定执行计划：列出执行步骤（不超过 5 步）和验收标准（不超过 5 条，必须可检查）。直接给计划，不要寒暄。
                \(inherited.isEmpty ? "" : "前序迭代上下文（本段必须延续，不要推翻已确认的结论）：\n\(inherited)\n")
                任务：\(userPrompt)
                """
                let plan = try await self.pipelineModelCall(
                    channel: channel,
                    systemPrompt: "你是\(LingShuExpertProfileRegistry.projectManager.title)。\(LingShuExpertProfileRegistry.projectManager.mission)\n专业要点：\n\(LingShuExpertProfileRegistry.projectManager.knowledgeHighlights.map { "- \($0)" }.joined(separator: "\n"))",
                    userPrompt: planPrompt,
                    token: pipelineToken,
                    stageActor: "规划",
                    probe: &probe
                )
                self.appendTaskRecordMessage(taskRecordID, actor: "规划", role: LingShuExpertProfileRegistry.projectManager.title, kind: .agent, text: plan)

                // ② 草稿：领域专家按模板产出交付物，流式上屏。
                self.missionTitle = "专家产出中"
                self.missionStatus = "\(expert.title)正在按模板产出交付物草稿。"
                let draftPrompt = """
                按你的专家档案产出本任务的完整交付物。要求：完整可落地，不要大纲后停下反问，不要提及内部流程。
                执行计划与验收标准（产出必须满足）：
                \(plan)
                \(inherited.isEmpty ? "" : "前序迭代上下文：\n\(inherited)\n")
                任务：\(userPrompt)
                """
                draft = try await self.pipelineModelCall(
                    channel: channel,
                    systemPrompt: expert.promptBlock,
                    userPrompt: draftPrompt,
                    token: pipelineToken,
                    stageActor: "执行",
                    streamInto: bubbleID,
                    probe: &probe
                )
                self.appendTaskRecordMessage(taskRecordID, actor: "执行", role: expert.title, kind: .agent, text: draft)

                // ③ 评审：评审官对照验收标准与专家清单逐条核对。
                self.missionTitle = "评审中"
                self.missionStatus = "评审官正在对照验收标准核对草稿。"
                let critiquePrompt = """
                对照验收标准和检查清单评审下面的草稿。
                验收标准：
                \(plan)
                检查清单：
                \(expert.reviewChecklist.map { "- \($0)" }.joined(separator: "\n"))
                草稿：
                \(draft)
                """
                let critique = try await self.pipelineModelCall(
                    channel: channel,
                    systemPrompt: reviewer.promptBlock,
                    userPrompt: critiquePrompt,
                    token: pipelineToken,
                    stageActor: "审议",
                    probe: &probe
                )
                self.appendTaskRecordMessage(taskRecordID, actor: "审议", role: reviewer.title, kind: .review, text: critique)

                // ④ 纠正：评审结论为"需修正"时打回，专家按意见修订一轮。
                var finalDraft = draft
                var corrected = false
                if critique.contains("需修正") {
                    corrected = true
                    self.missionTitle = "纠正中"
                    self.missionStatus = "\(expert.title)正在按评审意见修订交付物。"
                    self.appendTaskRecordMessage(taskRecordID, actor: "调度", role: "过程纠偏", kind: .router, text: "评审未通过，草稿打回\(expert.title)按意见修订。")
                    let revisePrompt = """
                    你的草稿被评审打回。逐条吸收下面的评审意见，输出修订后的完整交付物（全文，不要只列改动）。
                    评审意见：
                    \(critique)
                    原草稿：
                    \(draft)
                    """
                    finalDraft = try await self.pipelineModelCall(
                        channel: channel,
                        systemPrompt: expert.promptBlock,
                        userPrompt: revisePrompt,
                        token: pipelineToken,
                        stageActor: "纠正",
                        probe: &probe
                    )
                    self.appendTaskRecordMessage(taskRecordID, actor: "纠正", role: expert.title, kind: .agent, text: finalDraft)
                }

                // ⑤ 验收：最终结论 + 下一步建议。
                self.missionTitle = "验收中"
                self.missionStatus = "验收官正在给出最终结论。"
                let verdictText = try await self.pipelineModelCall(
                    channel: channel,
                    systemPrompt: "你是验收官。对照验收标准给出最终验收结论（120 字以内），并给一条具体的下一步建议。不要复述交付物。",
                    userPrompt: "验收标准：\n\(plan)\n\n最终交付物：\n\(finalDraft)",
                    token: pipelineToken,
                    stageActor: "验证",
                    probe: &probe
                )
                self.appendTaskRecordMessage(taskRecordID, actor: "验证", role: "验收官", kind: .review, text: verdictText)

                guard self.activePipelineToken == pipelineToken else { return }
                self.concludePipeline(
                    userPrompt: userPrompt,
                    route: route,
                    taskRecordID: taskRecordID,
                    threadID: threadID,
                    bubbleID: bubbleID,
                    expert: expert,
                    finalDraft: finalDraft,
                    verdictText: verdictText,
                    corrected: corrected,
                    probe: probe
                )
            } catch {
                guard self.activePipelineToken == pipelineToken else { return }
                self.failPipeline(
                    userPrompt: userPrompt,
                    route: route,
                    taskRecordID: taskRecordID,
                    bubbleID: bubbleID,
                    partialDraft: draft,
                    error: error
                )
            }
        }
    }

    // MARK: - 收尾与失败

    private func concludePipeline(
        userPrompt: String,
        route: CodexRoutePayload,
        taskRecordID: String?,
        threadID: String?,
        bubbleID: UUID,
        expert: LingShuExpertProfile,
        finalDraft: String,
        verdictText: String,
        corrected: Bool,
        probe: LingShuStreamLatencyProbe
    ) {
        executionPipelineTask = nil
        activePipelineToken = nil
        isModelExecuting = false
        appendTrace(kind: .system, actor: "调度", title: "管线延迟", detail: probe.summary())

        let finalReply = postProcessExecutionReply(finalDraft, for: userPrompt, route: route)
        completeRouteExecution(route)
        completeTaskRuntime(for: userPrompt, reply: finalReply, taskRecordID: taskRecordID)
        mainThreadKernel.observeExecution(prompt: userPrompt, summary: finalReply, completed: true)
        rememberMainThreadTurn(prompt: userPrompt, reply: finalReply, route: route)
        if let threadID {
            memoryService.rememberTask(prompt: userPrompt, status: "delivered", summary: String(finalReply.prefix(280)), taskID: threadID, taskRecordID: taskRecordID)
        }
        finalizeStreamingBubble(bubbleID, text: finalReply, taskRecordID: taskRecordID)
        let artifacts = materializeTaskArtifacts(for: userPrompt, route: route, reply: finalReply, taskRecordID: taskRecordID)

        // 主动汇报：任务收口由灵枢主动发起，不等用户来问。
        let report = """
        任务完成，给你汇报：
        · 交付：\(expert.title)主笔\(artifacts.isEmpty ? "，成果在上面这条消息里" : "，已落地 \(artifacts.count) 个文件（任务记录可预览）")。
        · 过程：规划 → 专家产出 → 评审\(corrected ? "（首稿被打回，已按意见修正）" : "（一次通过）") → 验收。
        · 验收：\(verdictText)
        """
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "主动汇报", kind: .result, text: report)
        chatMessages.append(.init(speaker: "灵枢", text: report, isUser: false, taskRecordID: taskRecordID))
        finishTaskRecord(taskRecordID, status: .completed, summary: report)
        logEvent("现在  协同管线完成并已主动汇报。")
    }

    private func failPipeline(
        userPrompt: String,
        route: CodexRoutePayload,
        taskRecordID: String?,
        bubbleID: UUID,
        partialDraft: String,
        error: Error
    ) {
        executionPipelineTask = nil
        activePipelineToken = nil
        isModelExecuting = false
        let message = routePlanner.modelGatewayErrorMessage(error)
        appendTrace(kind: .warning, actor: "调度", title: "管线中断", detail: message)
        appendTaskRecordMessage(taskRecordID, actor: "调度", role: "任务编排", kind: .warning, text: "协同管线中断：\(message)")

        if !partialDraft.isEmpty {
            // 草稿已产出：降级交付草稿并如实说明评审未完成。
            let reply = postProcessExecutionReply(partialDraft, for: userPrompt, route: route)
            finalizeStreamingBubble(bubbleID, text: reply, taskRecordID: taskRecordID)
            materializeTaskArtifacts(for: userPrompt, route: route, reply: reply, taskRecordID: taskRecordID)
            let notice = "汇报：专家草稿已交付，但评审/验收环节中断（\(message)）。这份成果未经完整核对，建议你过目或让我稍后重新验收。"
            chatMessages.append(.init(speaker: "灵枢", text: notice, isUser: false, taskRecordID: taskRecordID))
            appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "主动汇报", kind: .result, text: notice)
            finishTaskRecord(taskRecordID, status: .completed, summary: notice)
            completeRouteExecution(route)
            completeTaskRuntime(for: userPrompt, reply: reply, taskRecordID: taskRecordID)
            return
        }

        enterCoreState(.abnormal)
        blockTaskRuntime(message)
        let failureReply = "任务管线在专家产出前中断，我没有可靠成果可交付。原因：\(message)。你可以稍后让我重试。"
        finalizeStreamingBubble(bubbleID, text: failureReply, taskRecordID: taskRecordID)
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: failureReply)
        finishTaskRecord(taskRecordID, status: .blocked, summary: failureReply)
    }

    // MARK: - 任务级上下文

    /// 同任务前序迭代的继承上下文：取本记录关联的历史执行记录结论（严格任务内，
    /// 不混入聊天历史，保证不同任务相互隔离）。
    func taskIterationContext(threadID: String?, currentRecordID: String?) -> String {
        var priorRecords: [LingShuTaskExecutionRecord] = []

        if let currentRecordID,
           let current = taskExecutionRecordLookup.first(where: { $0.id == currentRecordID }) {
            priorRecords = current.relatedRecordIDs.compactMap { relatedID in
                taskExecutionRecordLookup.first { $0.id == relatedID }
            }
        }
        if priorRecords.isEmpty, let threadID,
           let thread = taskThreads.first(where: { $0.id == threadID }) {
            let completedRecordIDs = thread.segments
                .filter { $0.recordID != currentRecordID && $0.completedAt != nil }
                .map(\.recordID)
            priorRecords = completedRecordIDs.compactMap { recordID in
                taskExecutionRecordLookup.first { $0.id == recordID }
            }
        }

        guard !priorRecords.isEmpty else { return "" }
        return priorRecords
            .suffix(3)
            .map { "- 「\($0.title)」（\($0.status.rawValue)）：\(String($0.summary.prefix(220)))" }
            .joined(separator: "\n")
    }

    // MARK: - 管线模型调用

    struct PipelineChannel {
        var provider: String
        var model: String
        var endpoint: String
        var protocolName: String
        var apiKey: String
        var temperature: Double
        var timeout: TimeInterval
        var useStreaming: Bool
    }

    /// 单阶段模型调用：上下文严格任务内（不带聊天历史），按需把正文流式写入气泡。
    private func pipelineModelCall(
        channel: PipelineChannel,
        systemPrompt: String,
        userPrompt: String,
        token: UUID,
        stageActor: String,
        streamInto bubbleID: UUID? = nil,
        probe: inout LingShuStreamLatencyProbe
    ) async throws -> String {
        let request = LingShuRemoteModelRequest(
            provider: channel.provider,
            model: channel.model,
            endpoint: channel.endpoint,
            protocolName: channel.protocolName,
            apiKey: channel.apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: channel.temperature,
            stream: channel.useStreaming,
            timeout: channel.timeout,
            continuationToken: nil,
            conversationMessages: []
        )

        let reply: LingShuRemoteModelReply
        if channel.useStreaming {
            let parser = currentReplyAdapter.makeStreamParser()
            var localProbe = probe
            reply = try await remoteModelClient.stream(request) { [weak self] delta in
                Task { @MainActor in
                    guard let self, self.activePipelineToken == token else { return }
                    let event = parser.ingest(delta)
                    localProbe.observeDelta(hasContent: !event.contentDelta.isEmpty)
                    self.consumeModelStreamEvent(event, actor: stageActor, thinkingMessageID: bubbleID) { content in
                        if bubbleID != nil {
                            self.appendStreamingBubbleText(content, to: bubbleID)
                        }
                    }
                }
            } onHeartbeat: { [weak self] in
                Task { @MainActor in
                    guard let self, self.activePipelineToken == token else { return }
                    self.recordModelHeartbeat(source: stageActor, detail: "流式连接活跃。")
                }
            }
            probe = localProbe
            _ = parser.finish()
        } else {
            reply = try await remoteModelClient.send(request)
            probe.observeDelta(hasContent: true)
        }

        guard activePipelineToken == token, !Task.isCancelled else {
            throw CancellationError()
        }
        recordModelUsage(reply, stage: stageActor)
        return currentReplyAdapter.normalizedReplyText(reply.text)
    }
}
