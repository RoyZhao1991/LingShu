import Foundation

@MainActor
extension LingShuState {
    var isAutonomousRunActive: Bool {
        autonomousRun.isActive
    }

    var autonomousRunDisplayStatus: String {
        switch autonomousRun.phase {
        case .idle:
            return "未启用"
        case .probing, .planning, .ready, .running, .paused, .completed, .blocked:
            return autonomousRun.phase.rawValue
        }
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
        enterAutonomousRunningState(statusLine: "已授权，独立运行开始。")
        missionTitle = "独立运行中"
        missionStatus = "我用统一 agent 循环自主推进（真工具 + 独立 verifier 验收），保留暂停、继续和停止接管。"
        resetAgentRuntime(title: "独立运行中", status: "agent 循环按权限级（\(autonomousRun.permissionLevel.rawValue)）执行。")
        appendTrace(kind: .runtime, actor: "独立运行", title: "授权执行", detail: autonomousRun.statusLine)
        launchAutonomousExecution(continuing: false)
    }

    func pauseAutonomousRun() {
        guard autonomousRun.phase == .running else { return }
        autonomousRunTask?.cancel()
        autonomousRunTask = nil
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
        enterAutonomousRunningState(statusLine: "已从暂停恢复，继续推进。")
        appendTrace(kind: .runtime, actor: "独立运行", title: "继续运行", detail: "续接已持有的执行会话。")
        launchAutonomousExecution(continuing: autonomousSessionHolder != nil)
    }

    func stopAutonomousRun() {
        guard autonomousRun.phase != .idle else { return }
        let previousObjective = autonomousRun.objective
        autonomousRunTask?.cancel()
        autonomousRunTask = nil
        autonomousSessionHolder = nil
        autonomousPendingQuestion = nil
        autonomousRunRecordID = nil
        autonomousRun = .idle
        missionTitle = "待机中"
        missionStatus = "独立运行已停止。"
        enterCoreState(.standby, resetTimer: false)
        resetAgentRuntime()
        appendTrace(kind: .warning, actor: "用户", title: "停止独立运行", detail: previousObjective)
    }

    // MARK: - 自主执行（统一 agent 循环驱动，复用主会话同一引擎）

    /// 把 run 切到「执行中」并推进 runbook 步态（首个待执行步标为执行中）。
    private func enterAutonomousRunningState(statusLine: String) {
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
            let session: LingShuAgentSession
            let kickoff: String
            if continuing, let held = self.autonomousSessionHolder {
                session = held
                kickoff = "继续推进未完成的目标，直到达成或确实卡住。"
            } else {
                session = await self.makeAutonomousSession(objective: objective, permissionLevel: permissionLevel, runbook: runbook)
                self.autonomousSessionHolder = session
                kickoff = self.autonomousKickoffPrompt(objective: objective, runbook: runbook)
            }
            let result = await self.driveAgentDelivery(session: session, prompt: kickoff, taskRecordID: recordID)
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID)
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

        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let initial = await session.resume(prompt)
            let result = await self.verifyAndContinue(session: session, result: initial, userRequest: objective, taskRecordID: recordID)
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
    ) async -> LingShuAgentSession {
        let policy = autonomousExecutionPolicy(for: permissionLevel)
        let adapter = makeAgentModelAdapter()
        adapter.onReasoning = { [weak self] aside in   // 边做边想:每步旁白落进独立运行记录
            Task { @MainActor in self?.recordAgentReasoning(aside, recordID: self?.autonomousRunRecordID) }
        }
        var tools = agentBuiltinTools(recordIDProvider: { [weak self] in self?.autonomousRunRecordID }, executionPolicy: policy)
        tools += [Self.timeTool(), Self.webSearchTool(), recallMemoryTool(), rememberCredentialTool(), listCredentialsTool(), speakTool(), Self.askUserTool()] + previewTools()
        if policy != .readOnly {
            tools.append(spawnTaskTool(adapter: adapter))   // 观察模式不派生可写子任务
            tools += computerControlTools()                  // 计算机直接操作四肢(完整授权档自动放行,计划 §9)
            tools += backgroundWatchTools()                  // 后台守候 + 完成即续
        }
        return LingShuAgentSession(
            id: "autonomous-\(UUID().uuidString.prefix(6))",
            system: autonomousSystemPrompt(objective: objective, permissionLevel: permissionLevel, runbook: runbook),
            initialMessages: await seededDistilledMemory(),
            tools: tools,
            model: adapter,
            maxTurns: 80   // 自主运行可长程;安全天花板,非目标预算
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

    private func autonomousSystemPrompt(
        objective: String,
        permissionLevel: LingShuAutonomousPermissionLevel,
        runbook: LingShuAutonomousRunbook?
    ) -> String {
        let policyLine: String
        switch permissionLevel {
        case .observe:
            policyLine = "观察模式：只读分析与提醒，**不写文件、不执行命令、不调用外部工具**；给出发现和建议即可。"
        case .delegated:
            policyLine = "代理模式：可在工作目录内 write_file 生成产出物；run_command 等高风险动作在无人值守下会被安全拒绝，优先用文件类方式达成目标。"
        case .full:
            policyLine = "完整授权(完整电脑控制)：可自主 write_file/edit_file/run_command 真实执行，全程不必再请求授权，直到目标达成；只读命令(grep/find/ls…)我已为你免审批直放。**唯一例外**:删除或修改系统级敏感文件(/System、/usr、/etc、内核扩展等)仍会请你确认——别绕开它。"
        }
        return """
        你是灵枢(数字人),由 Roy Zhao 打造。**这是你的自主运行(Loop)模式:大脑是你自己的推理,四肢是你的各项能力(听/说/读/写/改代码/跑命令/联网/演示…)。** 目标交给你后,你自己分析→规划→推进→交付,像 codex 那样把事做完,**不要每步都等人确认、不要把该自己想的甩回来**;只有触及硬性网络/权限/物理限制才如实说明并指出需要什么组件。需要边做边讲(演示/汇报)就用 `speak` 出声。
        - 权限级：\(permissionLevel.rawValue)。\(policyLine)
        - 工作目录：\(codexWorkingDirectory)。
        - **有产出物优先产出物**：凡需交付 PPT/文档/脚本/代码等，必须真用 write_file/run_command 落到工作目录并给出绝对路径，绝不只口头说“已完成”（观察模式除外）。
        - **有固化方案优先固化方案**：动手前先调 apply_skill 看有没有匹配的专家技能（含设计系统与自带生成器），有就按它推进，别从零硬写（观察模式仅参考其要点，不落盘）。
        - 自主模式尽量自行决断、按合理假设推进，**不要中途反复提问**；只有触及不可逆且无法假设的关键岔路才调用 ask_user。
        - 目标含多个互不相关子目标时用 spawn_task 并行派生；相关步骤本会话顺序做。
        - 需要最新/实时事实时调用 web_search，不要凭记忆瞎答。
        """
    }

    /// 首轮启动语：把目标 + runbook 降为「建议性上下文」喂给模型，由模型自行规划执行（不再当硬流程）。
    private func autonomousKickoffPrompt(objective: String, runbook: LingShuAutonomousRunbook?) -> String {
        var lines = ["独立运行目标：\(objective)"]
        if !autonomousAttachmentContext.isEmpty { lines.append(autonomousAttachmentContext) }   // 上传的文件素材
        if let runbook {
            if !runbook.assumptions.isEmpty { lines.append("已知假设：" + runbook.assumptions.joined(separator: "；")) }
            if !runbook.expectedArtifacts.isEmpty { lines.append("期望产出物：" + runbook.expectedArtifacts.joined(separator: "、")) }
            if !runbook.reviewGates.isEmpty { lines.append("验收要点：" + runbook.reviewGates.joined(separator: "、")) }
            let stepTitles = runbook.steps.map(\.title)
            if !stepTitles.isEmpty { lines.append("建议步骤（仅供参考，可自行规划）：" + stepTitles.joined(separator: " → ")) }
        }
        if let skillHint = matchedSkillHint(for: objective) { lines.append(skillHint) }
        lines.append("现在开始自主推进，直到目标达成；完成后用一句话总结产出物与结论。")
        return lines.joined(separator: "\n")
    }

    /// 收尾：按运行结果更新相位、runbook 步态、任务记录与对话。
    private func finishAutonomousRun(result: LingShuAgentRunResult, recordID: String) {
        autonomousRunTask = nil
        switch result {
        case .completed(let text):
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
            autonomousPendingQuestion = question
            updateAutonomousRun(phase: .paused, statusLine: "需要你确认后继续。")
            missionTitle = "独立运行待答复"
            missionStatus = question
            appendTaskRecordMessage(recordID, actor: "独立运行", role: "待答复", kind: .warning, text: question)
            chatMessages.append(.init(speaker: "灵枢", text: "⏸ 独立运行需要你定一下：\(question)\n（直接在对话里回复，我就继续推进）", isUser: false, taskRecordID: recordID))
            enterCoreState(.standby, resetTimer: false)
            appendTrace(kind: .warning, actor: "独立运行", title: "卡住待答复", detail: question)
        case .maxTurnsReached(let text):
            updateAutonomousRun(phase: .blocked, statusLine: "未能在限定步数内收尾。")
            autonomousPendingQuestion = nil
            missionTitle = "独立运行未收尾"
            missionStatus = "已达步数上限，请查看记录后决定继续或调整目标。"
            appendTaskRecordMessage(recordID, actor: "独立运行", role: "未收尾", kind: .warning, text: text)
            finishTaskRecord(recordID, status: .blocked, summary: text)
            chatMessages.append(.init(speaker: "灵枢", text: "⚠️ 独立运行到达步数上限仍未收尾：\(text)", isUser: false, taskRecordID: recordID))
            enterCoreState(.standby, resetTimer: false)
            appendTrace(kind: .warning, actor: "独立运行", title: "步数上限", detail: String(text.prefix(80)))
        }
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

    func tickAutonomousRun(now: Date = Date()) {
        guard autonomousRun.phase == .running else { return }
        var run = autonomousRun
        run.updatedAt = now
        if let startedAt = run.startedAt {
            run.statusLine = "独立运行中 \(formatElapsed(Int(now.timeIntervalSince(startedAt))))"
        }
        autonomousRun = run
    }

    func handleAutonomousRunCommandIfNeeded(
        prompt: String,
        taskRecordID: String?
    ) -> String? {
        guard isAutonomousRunCommand(prompt) else { return nil }

        let snapshot = prepareAutonomousRun(objective: prompt)
        let missing = snapshot.runbook?.missingInformation ?? []
        let response: String
        if snapshot.phase == .blocked {
            response = "独立运行模式已准备，但环境存在阻断项。先看运行态里的自检报告，把不可用项处理掉，我再接手推进。"
        } else if missing.isEmpty {
            response = "已进入独立运行模式。我完成了环境检测、自检和动态 runbook，等待你授权执行。"
        } else {
            response = "已进入独立运行模式。我先生成了动态 runbook，但还建议确认：\(missing.joined(separator: "、"))。你也可以直接授权我按当前假设推进。"
        }

        appendTaskRecordMessage(taskRecordID, actor: "独立运行", role: "环境检测", kind: .core, text: snapshot.environment?.summaryLine ?? "环境检测完成")
        appendTaskRecordMessage(taskRecordID, actor: "独立运行", role: "动态规划", kind: .router, text: snapshot.runbook?.summaryLine ?? "动态规划完成")
        appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "中枢", kind: .result, text: response)
        applyTaskRecordRoute(
            taskRecordID,
            route: .init(
                needsAgents: false,
                agents: [],
                directAnswer: response,
                finalAnswer: response,
                summary: "进入独立运行模式，已完成环境检测、自检和动态 runbook。"
            )
        )
        finishTaskRecord(taskRecordID, status: snapshot.phase == .blocked ? .blocked : .answered, summary: response)
        chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: taskRecordID))
        rememberMainThreadTurn(prompt: prompt, reply: response)
        return response
    }

    private func autonomousEnvironmentInput() -> LingShuAutonomousEnvironmentInput {
        .init(
            workingDirectory: codexWorkingDirectory,
            modelProvider: modelProvider,
            modelName: modelName,
            isModelConnected: isModelConnected,
            modelConnectionState: modelConnectionState,
            codexPermissionMode: codexPermissionMode,
            requireHumanApproval: requireHumanApproval,
            permissionLevel: autonomousPermissionLevel,
            voiceOutputEnabled: voiceOutputEnabled,
            voiceWakeListeningEnabled: voiceWakeListeningEnabled,
            memoryDigestAvailable: !persistedConversationDigest.isEmpty || hasMoreColdChatHistory,
            onlineAgentCount: agentRuntimeCounts.online,
            runningAgentCount: agentRuntimeCounts.running,
            pendingAgentCount: agentRuntimeCounts.pendingStart
        )
    }

    private func normalizedAutonomousObjective(from rawObjective: String?) -> String {
        // 优先用传入目标(独立运行专门输入框 / 命令解析);为空再退到对话主输入框。
        // **不再填占位串**——空就返回空,由 prepareAutonomousRun 拒绝启动(计划 §1)。
        let raw = rawObjective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (raw?.isEmpty == false ? raw : nil) ?? fallback
        guard !text.isEmpty else { return "" }
        let separators = ["目标是", "目标：", "目标:", "任务是", "任务：", "任务:"]
        for separator in separators where text.contains(separator) {
            let parts = text.components(separatedBy: separator)
            if let last = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
                return last
            }
        }
        return text
    }

    private func isAutonomousRunCommand(_ prompt: String) -> Bool {
        let normalized = normalizeMemoryText(prompt)
        let modeSignals = ["独立运行模式", "独立运行", "自主运行", "托管模式", "autopilot"]
        let actionSignals = ["进入", "启动", "开启", "准备", "开始"]
        return modeSignals.contains { normalized.contains($0) }
            && actionSignals.contains { normalized.contains($0) }
    }
}
