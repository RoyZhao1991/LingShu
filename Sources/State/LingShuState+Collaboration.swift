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

    /// 定时触发：到点的提醒/例行任务以插件来源进入主线程正常处理——
    /// 内容是任务就走协同管线，是提醒就由直答通道开口。
    func fireScheduledTriggersIfDue(now: Date) {
        let due = scheduledTriggers.fireDueTriggers(now: now)
        guard !due.isEmpty else { return }
        for trigger in due {
            appendTrace(kind: .system, actor: "定时触发", title: "到点执行", detail: "\(trigger.scheduleText)「\(trigger.title)」已触发，交给主线程处理。")
            chatMessages.append(.init(speaker: "灵枢", text: "⏰ 定时任务到点：\(trigger.title)，我现在处理。", isUser: false))
            _ = submitTextInput(trigger.prompt, source: .plugin("定时触发"), appendUserMessage: false)
        }
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
        // 留痕本轮主笔专家及来源——让"到底用没用 skill"在执行窗一眼可查。
        let expertSource = expert.id.hasPrefix("skill-curated-") ? "策展 skill"
            : (expert.id.hasPrefix("skill-") ? "用户 skill" : "内置出厂专家")
        appendTaskRecordMessage(taskRecordID, actor: "调度", role: "专家选择", kind: .router, text: "本轮主笔专家：\(expert.title)（来源：\(expertSource)）。")
        appendTrace(kind: .route, actor: "调度", title: "专家选择", detail: "\(expert.title)（\(expertSource)）")
        let reviewer = expertProfileRegistry.reviewerProfile()
        let threadID = activeTaskThread?.id
        let inherited = taskIterationContext(threadID: threadID, currentRecordID: taskRecordID)
        // 任务级文件隔离：每个管线在独立子目录落盘，并行任务互不污染。
        let taskWorkDir = makeTaskWorkingDirectory(for: threadID ?? taskRecordID ?? UUID().uuidString)
        // skill 自带且已过安全门控的生成器：写进工作目录，专家直接跑它产出交付物（不用从零写）。
        var bundledScriptHint = ""
        if let script = expert.bundledScript, let scriptName = expert.bundledScriptName {
            let scriptURL = URL(fileURLWithPath: taskWorkDir).appendingPathComponent(scriptName)
            if (try? script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil {
                bundledScriptHint = "\n本 skill 自带的生成器已就绪：\(scriptURL.path)（设计系统已内置、已过安全门控）。按交付模板把内容写成数据文件后，用 run_command 跑它产出真交付物，不要从零另写生成代码。\n"
                appendTaskRecordMessage(taskRecordID, actor: "调度", role: "技能装配", kind: .router, text: "已装配 \(expert.title) 自带生成器 \(scriptName)（安全门控通过），写入工作目录。")
            }
        }
        // 借鉴文章：召回同领域经验规则注入规划，避免重复踩坑（记忆复利）。
        let experienceRules = memoryService.recallExperienceRules(for: userPrompt)
        let pipelineToken = UUID()
        activePipelineToken = pipelineToken

        if !inherited.isEmpty {
            appendTaskRecordMessage(taskRecordID, actor: "记忆", role: "执行记忆", kind: .memory, text: "本段继承同任务前序迭代的结论，专家产出会在其基础上延续。")
        }
        if !experienceRules.isEmpty {
            appendTaskRecordMessage(taskRecordID, actor: "记忆", role: "经验规则", kind: .memory, text: "召回 \(experienceRules.count) 条同领域经验规则，已注入规划参考。")
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
                为下面的任务制定执行计划：列出执行步骤（不超过 5 步）和验收标准（不超过 5 条，每条必须是可逐条核对的具体断言）。直接给计划，不要寒暄。
                \(experienceRules.isEmpty ? "" : "过往同类任务沉淀的经验规则（务必纳入，避免重复踩坑）：\n\(experienceRules.map { "- \($0)" }.joined(separator: "\n"))\n")
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
                // 专家是**一条长命 agent 对话**：草稿 + 后续所有重做共享 expertThread，全程持续记忆
                // （工具调用 + 报错都留着），重做时带着前情继续——撞墙换方法，不再从零重撞。
                let expertThread = LingShuAgentThread()
                self.missionTitle = "专家产出中"
                self.missionStatus = "\(expert.title)正在按模板产出交付物草稿。"
                let draftPrompt = """
                按你的专家档案产出本任务的完整交付物。要求：完整可落地，不要大纲后停下反问，不要提及内部流程。
                需要在本机真实执行（生成文件、安装依赖、运行验证）就直接发 run_command，宿主会请用户授权后执行。\(bundledScriptHint)
                执行计划与验收标准（产出必须满足）：
                \(plan)
                \(inherited.isEmpty ? "" : "前序迭代上下文：\n\(inherited)\n")
                任务：\(userPrompt)
                """
                draft = try await self.pipelineAgenticCall(
                    channel: channel,
                    systemPrompt: expert.promptBlock,
                    userPrompt: draftPrompt,
                    token: pipelineToken,
                    stageActor: "执行",
                    taskRecordID: taskRecordID,
                    workingDirectory: taskWorkDir,
                    streamInto: bubbleID,
                    thread: expertThread,
                    probe: &probe
                )
                self.appendTaskRecordMessage(taskRecordID, actor: "执行", role: expert.title, kind: .agent, text: draft)

                // ③+④ 目标驱动循环：评审官按验收标准逐条 ✅/❌ 核对（含真实落盘产物），全部达标才算过；
                // 没达标就打回重做——**不设轮次上限，做到达标为止**。只有连续多轮压不下未达标项（真卡死）才交回用户，
                // 这是"无进展"探测、不是预算封顶（在持续进步时永不触发）。
                var finalDraft = draft
                var correctionRounds = 0
                var reviewPassed = false
                var lastCritique = ""
                var bestFailedCount = Int.max
                var noProgressRounds = 0
                var stuckHandoff = false
                // 固定时间戳：每轮按当前稿件重建交付文件、覆盖同一份（不堆积一堆 .pptx）。
                let artifactBuildClock = Date()
                var registeredArtifactLocations = Set<String>()
                let criteriaBlock = "验收标准：\n\(plan)\n专家检查清单：\n\(expert.reviewChecklist.map { "- \($0)" }.joined(separator: "\n"))"

                while true {
                    self.missionTitle = correctionRounds == 0 ? "落地+评审中" : "落地+评审中（第 \(correctionRounds) 轮重做）"
                    self.missionStatus = correctionRounds == 0
                        ? "正在把草稿落成真实交付文件并逐条核对验收标准。"
                        : "正在把第 \(correctionRounds) 轮重做稿落成真实文件并复核。"

                    // 关键修复：把当前稿件**先落成真实交付文件**（宿主确定性构建真 .pptx/.docx 等），
                    // 再交验收官核对——杜绝"交付物只在 conclude 才构建，验收期间盘上根本没文件→永远判❌→放弃"的死锁。
                    let landed = self.engineeringArtifactService.materializeArtifacts(
                        prompt: userPrompt, route: route, reply: finalDraft,
                        workingDirectory: taskWorkDir, now: artifactBuildClock
                    )
                    let realFiles = landed.filter { FileManager.default.fileExists(atPath: $0.location) }
                    for file in realFiles where !registeredArtifactLocations.contains(file.location) {
                        self.appendTaskRecordArtifact(taskRecordID, title: file.title, location: file.location, producer: file.producer)
                        registeredArtifactLocations.insert(file.location)
                    }
                    let realFilesBlock = realFiles.isEmpty
                        ? "已真实落盘的文件：（无——本轮没能产出任何真实交付文件）"
                        : "已真实落盘的文件（盘上确实存在，据此核对\"必须产出文件\"类标准）：\n"
                            + realFiles.map { "- \($0.title)：\($0.location)" }.joined(separator: "\n")

                    let critiquePrompt = """
                    逐条核对下面的\(correctionRounds == 0 ? "草稿" : "第 \(correctionRounds) 轮重做稿")是否满足每一条验收标准与检查清单。
                    \(criteriaBlock)
                    \(realFilesBlock)
                    待评审稿：
                    \(finalDraft)

                    核对规则：凡是"必须产出某文件/实物"的标准，以**上面真实落盘文件清单**为准——稿件里只声明"脚本已就绪/稍后生成"而盘上没有对应文件，该条判 ❌。
                    输出格式（严格遵守）：
                    1. 先逐条核对每一条标准，写清达标 / 未达标及理由（未达标必须写缺什么、怎么改）。
                    2. 然后**另起一行**输出机器统计，格式固定、只数标准条目本身（每条标准算一条，不要把说明/举例/引用里的 ✅❌ 算进去）：
                       核对统计 PASS=<达标条数> FAIL=<未达标条数>
                    3. 最后单独一行给结论：全部达标写「结论：通过」，只要有未达标写「结论：需修正」。
                    """
                    let critique = try await self.pipelineModelCall(
                        channel: channel,
                        systemPrompt: reviewer.promptBlock,
                        userPrompt: critiquePrompt,
                        token: pipelineToken,
                        stageActor: "审议",
                        probe: &probe
                    )
                    let checklist = LingShuChecklistVerdict.parse(critique)
                    self.appendTaskRecordMessage(taskRecordID, actor: "审议", role: reviewer.title, kind: .review, text: "\(checklist.summaryLine)\n\(critique)")
                    lastCritique = critique

                    if checklist.allPassed {
                        reviewPassed = true
                        break
                    }

                    // 进度信号：未达标项是否在被压下去。在进步就一直循环；连续 3 轮压不动才判卡死、交回用户。
                    if checklist.failedCount < bestFailedCount {
                        bestFailedCount = checklist.failedCount
                        noProgressRounds = 0
                    } else {
                        noProgressRounds += 1
                    }
                    if noProgressRounds >= 3 {
                        stuckHandoff = true
                        self.appendTaskRecordMessage(taskRecordID, actor: "调度", role: "过程纠偏", kind: .warning, text: "连续 \(noProgressRounds) 轮没能把未达标项压下去（仍 \(checklist.failedCount) 项不达标），我先停下来交回你——补充信息或换个方向，回复「继续」我接着推到达标。")
                        break
                    }

                    correctionRounds += 1
                    self.missionTitle = "重做中（第 \(correctionRounds) 轮）"
                    self.missionStatus = "\(expert.title)正在按未达标项做第 \(correctionRounds) 轮重做（不设上限，做到达标为止）。"
                    self.appendTaskRecordMessage(taskRecordID, actor: "调度", role: "过程纠偏", kind: .router, text: "评审未通过（\(checklist.failedCount) 项未达标），打回\(expert.title)做第 \(correctionRounds) 轮重做。")

                    // 升级"换思路"力度：头两轮先把 ❌ 改到位；再不过就换结构性思路彻底重做，并鼓励真实执行。
                    let strategyDirective = correctionRounds <= 2
                        ? "把每个 ❌ 项改到位，输出修订后的完整交付物（全文，不要只列改动）。"
                        : "前 \(correctionRounds - 1) 轮的改法没能过审——**别再在原方案上小修小补，换一个结构性思路彻底重做**（不同的组织方式 / 技术路径 / 落地手段），从根上解决每个 ❌ 项。需要在本机真实执行（生成 .pptx/文件、跑命令、装依赖）就直接发 run_command，宿主会弹窗请用户授权后执行——别再用「给你段脚本自己跑」搪塞。"
                    let revisePrompt = """
                    你的稿件被评审打回（第 \(correctionRounds) 轮，目标驱动：做到逐条全部达标为止，不设轮次上限）。
                    \(strategyDirective)
                    **你上面这条对话里有你之前跑过的所有命令和报错——直接据此换个真正能跑通的方法，别重复撞同一堵墙。**
                    评审逐条结果：
                    \(critique)
                    """
                    finalDraft = try await self.pipelineAgenticCall(
                        channel: channel,
                        systemPrompt: expert.promptBlock,
                        userPrompt: revisePrompt,
                        token: pipelineToken,
                        stageActor: "纠正",
                        taskRecordID: taskRecordID,
                        workingDirectory: taskWorkDir,
                        thread: expertThread,
                        probe: &probe
                    )
                    self.appendTaskRecordMessage(taskRecordID, actor: "纠正", role: expert.title, kind: .agent, text: finalDraft)
                }
                let corrected = correctionRounds > 0
                _ = stuckHandoff

                // 借鉴文章：被打回又修正过的任务，把"问题→修正"提炼成经验规则沉淀（记忆复利）。
                if corrected {
                    await self.distillExperienceRule(channel: channel, token: pipelineToken, userPrompt: userPrompt, expert: expert, critique: lastCritique, taskRecordID: taskRecordID)
                }

                // ⑤ 验收：最终结论 + 下一步建议。
                self.missionTitle = "验收中"
                self.missionStatus = "验收官正在给出最终结论。"
                let verdictText = try await self.pipelineModelCall(
                    channel: channel,
                    systemPrompt: "你是验收官。对照验收标准逐条复核交付物，先用一两句给出每条是否达标，再给最终结论（达标/部分达标）和一条具体的下一步建议。总共不超过 160 字，不要复述交付物全文。",
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
                    reviewPassed: reviewPassed,
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
        reviewPassed: Bool,
        probe: LingShuStreamLatencyProbe
    ) {
        executionPipelineTask = nil
        activePipelineToken = nil
        isModelExecuting = false
        appendTrace(kind: .system, actor: "调度", title: "管线延迟", detail: probe.summary())

        let finalReply = postProcessExecutionReply(finalDraft, for: userPrompt, route: route)
        completeRouteExecution(route)
        completeTaskRuntime(for: userPrompt, reply: finalReply, taskRecordID: taskRecordID)
        rememberMainThreadTurn(prompt: userPrompt, reply: finalReply, route: route)
        finalizeStreamingBubble(bubbleID, text: finalReply, taskRecordID: taskRecordID)
        let artifacts = materializeTaskArtifacts(for: userPrompt, route: route, reply: finalReply, taskRecordID: taskRecordID)
        // 只认真实落到磁盘的文件——避免"声明了产物但盘上没有"的虚报。
        let realArtifacts = artifacts.filter { FileManager.default.fileExists(atPath: $0.location) }
        // 达标 = 评审三轮内通过。未通过就不许报"完成"。
        let delivered = reviewPassed

        mainThreadKernel.observeExecution(prompt: userPrompt, summary: finalReply, completed: delivered)
        if let threadID {
            memoryService.rememberTask(prompt: userPrompt, status: delivered ? "delivered" : "needs-revision", summary: String(finalReply.prefix(280)), taskID: threadID, taskRecordID: taskRecordID)
        }

        let report: String
        let status: LingShuTaskExecutionStatus
        if delivered {
            report = """
            任务完成，给你汇报：
            · 交付：\(expert.title)主笔\(realArtifacts.isEmpty ? "，成果在上面这条消息里" : "，已落地 \(realArtifacts.count) 个文件（任务记录可预览）")。
            · 过程：规划 → 专家产出 → 评审\(corrected ? "（首稿被打回，已按意见修正）" : "（一次通过）") → 验收。
            · 验收：\(verdictText)
            """
            status = .completed
        } else {
            // 评审未通过：诚实报「未达标」，绝不说"完成"。说清楚缺什么、下一步怎么推进。
            report = """
            任务未达标——我没有按"完成"上报：
            · 现状：\(expert.title)主笔，目标驱动多轮重做后仍卡在未达标项，\(realArtifacts.isEmpty ? "尚无可验收的成果文件落盘" : "已落地 \(realArtifacts.count) 个文件，但未达验收标准")。
            · 验收：\(verdictText)
            · 下一步：回复「继续」我就接着推到达标；需要在本机执行命令（如生成 .pptx 实文件）时会弹窗请你授权。
            """
            status = .needsRevision
        }
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "主动汇报", kind: .result, text: report)
        chatMessages.append(.init(speaker: "灵枢", text: report, isUser: false, taskRecordID: taskRecordID))
        finishTaskRecord(taskRecordID, status: status, summary: report)
        logEvent(delivered ? "现在  协同管线完成并已主动汇报。" : "现在  协同管线未达标，已诚实上报未完成。")
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
}
