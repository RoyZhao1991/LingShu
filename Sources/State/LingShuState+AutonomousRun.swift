import Foundation

@MainActor
extension LingShuState {
    var isAutonomousRunActive: Bool {
        autonomousRun.isActive
    }

    var autonomousRunDisplayStatus: String {
        autonomousRun.phase == .idle ? loc("未启用", "Off") : loc(autonomousRun.phase.rawValue, autonomousRun.phase.englishName)
    }

    @discardableResult
    func prepareAutonomousRun(objective rawObjective: String? = nil) -> LingShuAutonomousRunSnapshot {
        let now = Date()
        let objective = normalizedAutonomousObjective(from: rawObjective)
        // 空目标硬约束:有目标才允许启动(计划 §1 逻辑硬伤)。按钮已禁用,这里是防御性兜底。
        guard !objective.isEmpty else {
            missionTitle = "待机中"
            missionStatus = "请先在独立运行输入框填写目标(可上传文件 + 写指令),有目标才能启动。"
            appendTrace(kind: .warning, actor: "独立运行", title: "缺少目标", detail: "空目标已拒绝启动。")
            return autonomousRun
        }
        // 捕获本次上传附件的抽取上下文(随后清空附件托盘),启动后折入 kickoff 让大脑看到素材。
        autonomousAttachmentContext = attachmentContextBlock()
        clearAttachments()
        autonomousObjectiveDraft = ""
        let environment = autonomousEnvironmentProbe.run(input: autonomousEnvironmentInput(), now: now)
        let memoryStatus = [
            mainMemoryStatus,
            coldMemoryStatus,
            persistedConversationDigest.isEmpty ? nil : "冷历史摘要可用"
        ].compactMap { $0 }.joined(separator: "；")
        let runbook = autonomousRunbookPlanner.plan(
            objective: objective,
            permissionLevel: autonomousPermissionLevel,
            environment: environment,
            memoryStatus: memoryStatus.isEmpty ? "本轮先按主线程记忆检索结果推进。" : memoryStatus
        )
        let selfCheck = autonomousSelfCheckRunner.run(environment: environment, runbook: runbook, now: now)
        let phase: LingShuAutonomousRunPhase = environment.canRun ? .ready : .blocked
        let status = phase == .ready
            ? "独立运行计划已生成，等待授权执行。"
            : "独立运行存在阻断项，请先处理环境或模型通道。"

        autonomousRun = .init(
            id: "auto-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))",
            objective: objective,
            phase: phase,
            permissionLevel: autonomousPermissionLevel,
            environment: environment,
            selfCheck: selfCheck,
            runbook: runbook,
            statusLine: status,
            startedAt: nil,
            updatedAt: now
        )
        missionTitle = phase == .ready ? "独立运行待授权" : "独立运行阻断"
        missionStatus = "\(environment.summaryLine)；\(runbook.summaryLine)"
        appendTrace(kind: .system, actor: "独立运行", title: "环境检测", detail: environment.summaryLine)
        appendTrace(kind: .route, actor: "独立运行", title: "动态规划", detail: runbook.summaryLine)
        appendTrace(kind: phase == .ready ? .result : .warning, actor: "独立运行", title: phase.rawValue, detail: status)
        return autonomousRun
    }

    func authorizeAutonomousRun() {
        guard autonomousRun.phase == .ready || autonomousRun.phase == .paused else { return }
        let standing = autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        enterAutonomousRunningState(statusLine: standing ? "灵枢已上岗，在岗待命。" : "已授权，独立运行开始。")
        missionTitle = standing ? "灵枢在岗" : "独立运行中"
        missionStatus = standing
            ? "我已上岗：能听、能说、能思考、能动手。你用对话或语音自然驱动我，我按权限级（\(autonomousRun.permissionLevel.rawValue)）推进。"
            : "我用统一 agent 循环自主推进（真工具 + 独立 verifier 验收），保留暂停、继续和停止接管。"
        resetAgentRuntime(title: missionTitle, status: "agent 循环按权限级（\(autonomousRun.permissionLevel.rawValue)）执行。")
        appendTrace(kind: .runtime, actor: standing ? "灵枢" : "独立运行", title: standing ? "上岗" : "授权执行", detail: autonomousRun.statusLine)
        launchAutonomousExecution(continuing: false)
    }

    func pauseAutonomousRun() {
        guard autonomousRun.phase == .running else { return }
        // **演示在播 → 把演示 play 循环也暂停**(停在当前页,继续时从这页接着念)。否则只停了自主循环+掐一下 TTS,
        // 而我的 presentationController.play 循环还在后台推页/念稿,UI 看着「已暂停」声音/画面却继续(2026-06-25 用户实测 bug)。
        if presentationController.isActive { presentationController.requestPauseForQA() }
        autonomousRunTask?.cancel()
        autonomousRunTask = nil
        // **暂停=立刻安静(2026-06-20 修"已暂停但音频还在输出")**:cancel 任务只停模型循环,**正在播/排队的 TTS 不会因此停**;
        // run_steps 批量(演示逐句念)也得停。暂停就该立刻静下来,否则状态机看着暂停、声音还在念=不一致。
        batchInterruptRequested = true        // 停 run_steps 批量(别再翻页/念下一句)
        interruptSpeechOutput?()              // 掐当前 TTS + 流式发声队列
        endAutonomousActivity()   // 暂停:释放 App Nap 抑制
        var run = autonomousRun
        run.phase = .paused
        run.updatedAt = Date()
        run.statusLine = "已暂停，等待继续或停止。"
        autonomousRun = run
        missionTitle = "独立运行已暂停"
        missionStatus = "我已停止推进，保留当前 runbook 和执行会话上下文。"
        enterCoreState(.standby, resetTimer: false)
        appendTrace(kind: .warning, actor: "用户", title: "暂停独立运行", detail: run.statusLine)
    }

    func resumeAutonomousRun() {
        guard autonomousRun.phase == .paused else { return }
        // 卡在提问上：答案要在对话里回复（handleAutonomousAnswerIfNeeded 接管），不能空续。
        if autonomousPendingQuestion != nil {
            missionStatus = "我在等你回答上一个问题，请在对话里回复，我就继续。"
            appendTrace(kind: .warning, actor: "独立运行", title: "等待答复", detail: autonomousPendingQuestion ?? "")
            return
        }
        // **演示被暂停 → 从暂停页继续演示**(不是去续自主循环)。否则「继续」按钮不会让演示接着念(2026-06-25 bug)。
        if presentationController.phase == .pausedForQA {
            enterAutonomousRunningState(statusLine: "继续演示。")
            appendTrace(kind: .runtime, actor: "演示与答疑", title: "继续演示", detail: "从暂停页接着念。")
            presentationPlaybackTask?.cancel()
            presentationPlaybackTask = Task { @MainActor [weak self] in await self?.presentationController.resume() }
            return
        }
        enterAutonomousRunningState(statusLine: "已从暂停恢复，继续推进。")
        appendTrace(kind: .runtime, actor: "独立运行", title: "继续运行", detail: "续接已持有的执行会话。")
        launchAutonomousExecution(continuing: autonomousSessionHolder != nil)
    }

    func stopAutonomousRun() {
        guard autonomousRun.phase != .idle else { return }
        // **退出时也彻底停演示**:否则只关了预览窗、我的 presentationController play 循环还在后台念稿/推页,
        // 且 presentation 仍 isActive → 之后再发「演示」会被确定性路由挡掉、转给大脑追问(2026-06-25 实测)。
        stopPresentationIfActive()
        let previousObjective = autonomousRun.objective
        autonomousRunTask?.cancel()
        autonomousRunTask = nil
        autonomousSessionHolder = nil
        autonomousPendingQuestion = nil
        autonomousRunRecordID = nil
        _ = previewController.close()    // **退出必恢复屏幕**:关预览 + 退全屏(防演示黑屏卡死后夺不回)
        Task { @MainActor in await agentOrchestrator.cancelAllRunning() }   // 停掉后台跑飞的演示/任务
        endAutonomousActivity()          // 释放 App Nap 抑制
        teardownAutonomousPerception()   // 收住周期感知循环(停 VL/音频 + 清 digest)
        autonomousRun = .idle
        missionTitle = "待机中"
        missionStatus = "独立运行已停止。"
        enterCoreState(.standby, resetTimer: false)
        resetAgentRuntime()
        appendTrace(kind: .warning, actor: "用户", title: "停止独立运行", detail: previousObjective)
    }

    // MARK: - 自主执行（统一 agent 循环驱动，复用主会话同一引擎）

    /// 把 run 切到「执行中」并推进 runbook 步态（首个待执行步标为执行中）。
    /// 注：非 private——常驻灵枢扩展（LingShuState+StandingPerson）也复用它。
    func enterAutonomousRunningState(statusLine: String) {
        var run = autonomousRun
        run.phase = .running
        run.startedAt = run.startedAt ?? Date()
        run.updatedAt = Date()
        run.statusLine = statusLine
        if var runbook = run.runbook,
           let index = runbook.steps.firstIndex(where: { $0.status == .waiting }) {
            runbook.steps[index].status = .running
            run.runbook = runbook
        }
        autonomousRun = run
        beginAutonomousActivity()   // 抑制 App Nap:运行/在岗期间灵枢常在后台操作别的 app,心跳不能被暂停
        enterCoreState(.executing)
    }

    /// 启动（或续接）自主执行：用 driveAgentDelivery 跑统一 agent 循环，收尾交 finishAutonomousRun。
    private func launchAutonomousExecution(continuing: Bool) {
        interruptSpeechOutput?()
        let objective = autonomousRun.objective
        let permissionLevel = autonomousRun.permissionLevel
        let runbook = autonomousRun.runbook
        let recordID = autonomousRunRecordID ?? createTaskExecutionRecord(for: "独立运行：\(objective)")
        autonomousRunRecordID = recordID
        installAgentEventSinkIfNeeded()

        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let session: any LingShuAgentSessioning
            let kickoff: String
            if continuing, let held = self.autonomousSessionHolder {
                session = held
                kickoff = "继续推进未完成的目标，直到达成或确实卡住。"
            } else {
                session = await self.makeAutonomousSession(objective: objective, permissionLevel: permissionLevel, runbook: runbook)
                self.autonomousSessionHolder = session
                kickoff = self.resolveKickoffPrompt(objective: objective, runbook: runbook)
            }
            // P1+P2 全入口覆盖:自主运行的**真实目标**(非续跑、非空在岗)前置认知=GoalSpec + 能力缺口分析,绑定记录 → 同样被执行引导/验收/经验消费。
            if self.goalSpecEnabled, !continuing,
               !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               self.goalSpec(for: recordID) == nil || self.gapAnalysis(for: recordID) == nil {
                await self.bindPreflightCognition(request: objective, recordID: recordID)
            }
            let result: LingShuAgentRunResult
            let isStandingKickoff = objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !continuing
            if isStandingKickoff {
                // 常驻上岗开场白:用**无工具一次性会话**生成一句招呼。主会话带 speak 工具会一边出声(①)
                // 一边产出回复气泡被自动朗读(②)→ 双份音频(实测日志确认);无工具会话只回一句文本 → 自动朗读念一次。
                let greeter = LingShuAgentSession(
                    id: "greet-\(UUID().uuidString.prefix(6))",
                    system: "你是灵枢,刚上岗。用一句自然的话向主人示意你已就位待命即可。**别自我介绍、别用具体名字称呼(历史里的名字可能是误识别)、别调任何工具**,只输出这一句招呼。",
                    tools: [],
                    model: self.makeAgentModelAdapter(),
                    maxTurns: 1
                )
                result = await greeter.send("打个招呼,一句话。")
            } else if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = await session.send(kickoff)   // 在岗续跑(continuing)等:走主会话
            } else {
                result = await self.driveAgentDelivery(session: session, prompt: kickoff, taskRecordID: recordID)
            }
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID, isKickoffGreeting: isStandingKickoff)
        }
    }

    /// 自主运行卡在 ask_user 时，把下一条用户输入当答案回填、续跑执行会话。
    /// 返回非 nil 表示已接管本轮输入（不再走常规 agent 主入口）。
    func handleAutonomousAnswerIfNeeded(prompt: String, taskRecordID: String?) -> String? {
        guard autonomousRun.phase == .paused,
              autonomousPendingQuestion != nil,
              let session = autonomousSessionHolder else { return nil }
        autonomousPendingQuestion = nil
        let recordID = autonomousRunRecordID ?? createTaskExecutionRecord(for: "独立运行：\(autonomousRun.objective)")
        autonomousRunRecordID = recordID
        let objective = autonomousRun.objective
        enterAutonomousRunningState(statusLine: "已收到答复，继续推进。")
        appendTaskRecordMessage(recordID, actor: "用户", role: "答复", kind: .core, text: prompt)
        appendTrace(kind: .runtime, actor: "独立运行", title: "收到答复续跑", detail: String(prompt.prefix(40)))

        let baseline = currentArtifactCount(recordID)
        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let initial = await session.resume(prompt)
            let result = await self.verifyAndContinue(session: session, result: initial, userRequest: objective, taskRecordID: recordID, artifactBaseline: baseline)
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID)
        }
        let ack = "收到，我继续推进独立运行。"
        chatMessages.append(.init(speaker: "灵枢", text: ack, isUser: false, taskRecordID: recordID))
        return ack
    }

    /// 构造自主执行会话：复用 agentBuiltinTools 全工具集（含 MCP）+ 通用工具，权限级映射执行策略。
    private func makeAutonomousSession(
        objective: String,
        permissionLevel: LingShuAutonomousPermissionLevel,
        runbook: LingShuAutonomousRunbook?
    ) async -> any LingShuAgentSessioning {
        let policy = autonomousExecutionPolicy(for: permissionLevel)
        let adapter = makeAgentModelAdapter()
        adapter.onReasoning = { [weak self] aside in   // 边做边想:每步旁白落进独立运行记录
            Task { @MainActor in self?.recordAgentReasoning(aside, recordID: self?.autonomousRunRecordID) }
        }
        var tools = agentBuiltinTools(recordIDProvider: { [weak self] in self?.autonomousRunRecordID }, executionPolicy: policy)
        tools += [Self.timeTool(), Self.locationTool(), webSearchTool(), recallMemoryTool(), perceiveTool(), pushNotificationTool(), rememberCredentialTool(), listCredentialsTool(), speakTool(), digitalHumanTool(), Self.askUserTool()] + previewTools() + browserTools()
        if policy != .readOnly {
            tools.append(spawnTaskTool(adapter: adapter))   // 观察模式不派生可写子任务
            tools += computerControlTools()                  // 计算机直接操作四肢(完整授权档自动放行,计划 §9)
            tools += backgroundWatchTools()                  // 后台守候 + 完成即续
            tools += scheduledTaskTools()                    // 定时调度(到时间点触发);在岗/自主主用模式必须有,否则又退回伪造 launchd
        }
        return makeAgentSession(
            id: "autonomous-\(UUID().uuidString.prefix(6))",
            system: autonomousSystemPrompt(objective: objective, permissionLevel: permissionLevel, runbook: runbook),
            initialMessages: await seededDistilledMemory(),
            tools: withPhaseTracking(withBatchRunner(tools)),   // run_steps 批量跑 + 相位跟踪(本体显示理解/规划/执行)
            model: adapter,
            maxTurns: 120,   // 自主运行长程;安全天花板(防失控),非目标预算——撞顶由验收续跑恢复
            recordIDProvider: { [weak self] in self?.autonomousRunRecordID }   // .nested 阶段验收据此定位在岗/自主记录
        )
    }

    /// 权限级 → 执行策略：观察=只读 / 代理=标准（shell 走审批门，无人值守按安全默认拒绝）/ 完整授权=直接放行。
    private func autonomousExecutionPolicy(for level: LingShuAutonomousPermissionLevel) -> LingShuAgentExecutionPolicy {
        switch level {
        case .observe:   return .readOnly
        case .delegated: return .standard
        case .full:      return .autoAllowShell
        }
    }

    /// 自主/在岗系统提示已拆至 [LingShuState+AutonomousPrompts.swift](LingShuState+AutonomousPrompts.swift)（守 ≤500 行架构守卫）。

    /// 收尾：按运行结果更新相位、runbook 步态、任务记录与对话。
    /// 注：非 private——常驻灵枢扩展（LingShuState+StandingPerson）的在岗续跑也复用它。
    func finishAutonomousRun(result: LingShuAgentRunResult, recordID: String, isKickoffGreeting: Bool = false) {
        autonomousRunTask = nil
        switch result {
        case .completed(let text):
            if Self.isCancellationSentinel(text) {
                settleStandingStreamBubble(text: "", recordID: recordID)
                updateAutonomousRun(phase: autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .running : .paused,
                                    statusLine: "上一轮已中断。")
                missionTitle = autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "灵枢在岗" : "独立运行已暂停"
                missionStatus = "上一轮已中断,等待下一步指令。"
                appendTaskRecordMessage(recordID, actor: "运行时", role: "取消收口", kind: .warning, text: "上一轮被新指令或停止动作取消,取消哨兵已吞掉,不作为正式回复展示。")
                enterCoreState(.standby, resetTimer: false)
                return
            }
            // 常驻灵枢：一段处理完后**保持在岗**，不收工——会话/记录留存，等下一句对话/语音。
            if autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateAutonomousRun(phase: .running, statusLine: "在岗待命。")
                autonomousPendingQuestion = nil
                missionTitle = "灵枢在岗"
                // **捎带汇报**:互动中完成的后台子任务攒在待汇报队列,趁这次主线程回复一起报给主人(开场招呼不捎带)。
                let reports = isKickoffGreeting ? "" : drainPendingSubtaskReports()
                let fullText = reports.isEmpty ? text : "\(text)\n\n另外,\(reports)"
                missionStatus = String(fullText.prefix(80))
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "在岗", kind: .result, text: fullText)
                if let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) { taskExecutionRecords[idx].status = .answered }
                // 在岗答复流式气泡定稿(逐字流式的临时文本→验收后最终回复);无流式气泡(开场招呼)才走原 append。
                if !settleStandingStreamBubble(text: fullText, recordID: recordID) {
                    // 上岗开场白:先把**尾部残留的旧招呼**去掉(每次上岗只留一句,不让历史里的招呼越堆越多),再追加这句并标记。
                    if isKickoffGreeting {
                        while let last = chatMessages.last, last.isStandingGreeting == true { chatMessages.removeLast() }
                    }
                    chatMessages.append(.init(speaker: "灵枢", text: fullText, isUser: false, taskRecordID: recordID, isStandingGreeting: isKickoffGreeting ? true : nil))
                }
                enterCoreState(.standby, resetTimer: false)
                appendTrace(kind: .result, actor: "灵枢", title: "在岗", detail: String(fullText.prefix(80)))
                return
            }
            endAutonomousActivity()   // 目标驱动运行已完成,释放 App Nap 抑制(常驻灵枢分支已在上方 return,仍保持)
            completeAutonomousRunbookSteps()
            updateAutonomousRun(phase: .completed, statusLine: "独立运行完成。")
            autonomousPendingQuestion = nil
            missionTitle = "独立运行已完成"
            missionStatus = String(text.prefix(80))
            appendTaskRecordMessage(recordID, actor: "独立运行", role: "交付", kind: .result, text: text)
            finishTaskRecord(recordID, status: .completed, summary: text)
            chatMessages.append(.init(speaker: "灵枢", text: "✅ 独立运行完成：\(text)", isUser: false, taskRecordID: recordID))
            rememberMainThreadTurn(prompt: "独立运行：\(autonomousRun.objective)", reply: text)
            enterCoreState(.standby, resetTimer: false)
            appendTrace(kind: .result, actor: "独立运行", title: "完成", detail: String(text.prefix(80)))
        case .blocked(let question):
            let cleanQuestion = LingShuHumanInputEnvelope.userFacingText(from: question)
            autonomousPendingQuestion = question
            updateAutonomousRun(phase: .paused, statusLine: "需要你确认后继续。")
            missionTitle = "独立运行待答复"
            missionStatus = cleanQuestion
            appendTaskRecordMessage(recordID, actor: "独立运行", role: "待答复", kind: .warning, text: cleanQuestion)
            settleStandingStreamBubble(text: "", recordID: recordID)   // 移除流式 partial,改用带选项的待答复气泡
            chatMessages.append(.init(speaker: "灵枢", text: "⏸ 独立运行需要你定一下：\(cleanQuestion)\n（直接在对话里回复，我就继续推进）", isUser: false, taskRecordID: recordID, choices: LingShuChoiceParsing.parse(question) ?? LingShuChoiceParsing.parse(cleanQuestion)))
            enterCoreState(.standby, resetTimer: false)
            appendTrace(kind: .warning, actor: "独立运行", title: "卡住待答复", detail: cleanQuestion)
        case .maxTurnsReached(let text):
            // **在岗(空 objective)特例(2026-06-19 修"问天气撞顶后退岗+无回复"):**在岗的一句对话/查询若没在限定步数内
            // 收尾(如外部数据源不可用反复重试),**绝不退岗、绝不当"独立运行失败"**——把已有的最好结果当回复贴给主人,保持在岗待命。
            // 原 bug:无此分支→走下面目标驱动处理→`endAutonomousActivity()` 把在岗停了(standing=False)+ 该给的答复成了"⚠️步数上限",
            // 主人遂"听到 TTS(回合内 speak 的)却看不到聊天回复、且灵枢悄悄下岗"。
            if autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateAutonomousRun(phase: .running, statusLine: "在岗待命。")
                autonomousPendingQuestion = nil
                missionTitle = "灵枢在岗"
                let reply = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "这件事我没能在几步内拿下(可能外部数据源暂时不可用),先停一下——要我换个方式再试吗?"
                    : text
                missionStatus = String(reply.prefix(80))
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "在岗", kind: .warning, text: reply)
                if let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) { taskExecutionRecords[idx].status = .answered }
                if !settleStandingStreamBubble(text: reply, recordID: recordID) {
                    chatMessages.append(.init(speaker: "灵枢", text: reply, isUser: false, taskRecordID: recordID))
                }
                enterCoreState(.standby, resetTimer: false)
                appendTrace(kind: .warning, actor: "灵枢", title: "在岗(未在步数内收尾)", detail: String(reply.prefix(80)))
                return
            }
            endAutonomousActivity()   // 撞步数上限收尾,释放 App Nap 抑制
            updateAutonomousRun(phase: .blocked, statusLine: "未能在限定步数内收尾。")
            autonomousPendingQuestion = nil
            missionTitle = "独立运行未收尾"
            missionStatus = "已达步数上限，请查看记录后决定继续或调整目标。"
            appendTaskRecordMessage(recordID, actor: "独立运行", role: "未收尾", kind: .warning, text: text)
            finishTaskRecord(recordID, status: .blocked, summary: text)
            chatMessages.append(.init(speaker: "灵枢", text: "⚠️ 独立运行到达步数上限仍未收尾：\(text)", isUser: false, taskRecordID: recordID))
            enterCoreState(.standby, resetTimer: false)
            appendTrace(kind: .warning, actor: "独立运行", title: "步数上限", detail: String(text.prefix(80)))
        case .interrupted(let reason):
            if LingShuModelServiceFailure.isNonRecoverableReason(reason) {
                let message = LingShuModelServiceFailure.userFacingReason(reason)
                let status = LingShuModelServiceFailure.decodeReason(reason)?.taskStatus ?? .failed
                settleStandingStreamBubble(text: "", recordID: recordID)
                suspendedAutonomousRecordID = nil
                updateAutonomousRun(phase: .blocked, statusLine: message)
                missionTitle = status == .waitingForUser ? "等待模型配置" : "模型服务异常"
                missionStatus = String(message.prefix(120))
                appendTaskRecordMessage(recordID, actor: "模型通道", role: "不可自动恢复", kind: .warning, text: message)
                finishTaskRecord(recordID, status: status, summary: message)
                chatMessages.append(.init(speaker: "灵枢", text: "⚠️ \(message)", isUser: false, taskRecordID: recordID))
                enterCoreState(.abnormal, resetTimer: false)
                appendTrace(kind: .warning, actor: "独立运行", title: "模型服务异常", detail: String(message.prefix(120)))
                return
            }
            // 网络中断:**非失败**——独立运行挂起,登记重连后自动续跑;会话上下文保留在 autonomousSessionHolder。
            settleStandingStreamBubble(text: "", recordID: recordID)   // 移除流式 partial(续跑时重建),不留 loading 气泡
            suspendedAutonomousRecordID = recordID
            updateAutonomousRun(phase: .paused, statusLine: "网络中断,已暂停,联网后自动续。")
            missionTitle = "独立运行已暂停(等网络)"
            missionStatus = String(reason.prefix(80))
            appendTaskRecordMessage(recordID, actor: "独立运行", role: "暂停", kind: .warning, text: "网络中断,已暂停:\(reason)")
            finishTaskRecord(recordID, status: .suspended, summary: "网络中断已暂停,联网后自动续跑。")
            enterCoreState(.standby, resetTimer: false)
            appendTrace(kind: .warning, actor: "独立运行", title: "网络中断暂停", detail: String(reason.prefix(80)))
            startNetworkRetryLoopIfNeeded()   // 启动主动重试(对话框可见进度)
        }
    }

    nonisolated static func isCancellationSentinel(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return compact.contains("本轮已被取消") || compact.contains("任务已取消")
    }

    /// 重连后续跑被网络中断挂起的独立运行(从中断处 continueLoop + 复用收尾)。
    func resumeSuspendedAutonomousIfNeeded() async {
        guard let recordID = suspendedAutonomousRecordID, let session = autonomousSessionHolder else { return }
        suspendedAutonomousRecordID = nil
        updateAutonomousRun(phase: .running, statusLine: "网络恢复,自动续跑中。")
        if let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) { taskExecutionRecords[idx].status = .running }
        let baseline = currentArtifactCount(recordID)
        var result = await session.continueLoop()
        result = await verifyAndContinue(session: session, result: result, userRequest: autonomousRun.objective, taskRecordID: recordID, artifactBaseline: baseline)
        if case .interrupted = result { suspendedAutonomousRecordID = recordID; return }  // 还连不上,留挂起
        finishAutonomousRun(result: result, recordID: recordID)
    }

    private func updateAutonomousRun(phase: LingShuAutonomousRunPhase, statusLine: String) {
        var run = autonomousRun
        run.phase = phase
        run.updatedAt = Date()
        run.statusLine = statusLine
        autonomousRun = run
    }

    private func completeAutonomousRunbookSteps() {
        guard var runbook = autonomousRun.runbook else { return }
        for index in runbook.steps.indices where runbook.steps[index].status != .blocked {
            runbook.steps[index].status = .completed
        }
        var run = autonomousRun
        run.runbook = runbook
        autonomousRun = run
    }

}
