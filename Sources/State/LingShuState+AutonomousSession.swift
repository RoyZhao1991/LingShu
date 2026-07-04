import Foundation

@MainActor
extension LingShuState {
    /// 待用户问题是否明确需要用户用文件/附件/路径来回答。
    /// 有附件的新输入默认应被视为新的 grounded turn,避免上一条"缺授权/缺信息"把后续附件任务吞掉。
    nonisolated static func pendingAutonomousQuestionAcceptsAttachment(_ raw: String) -> Bool {
        waitingQuestionAcceptsAttachment(raw)
    }

    /// 构造自主执行会话：复用 agentBuiltinTools 全工具集（含 MCP）+ 通用工具，权限级映射执行策略。
    func makeAutonomousSession(
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
    func autonomousExecutionPolicy(for level: LingShuAutonomousPermissionLevel) -> LingShuAgentExecutionPolicy {
        switch level {
        case .observe:   return .readOnly
        case .delegated: return .standard
        case .full:      return .autoAllowShell
        }
    }

    nonisolated static func isCancellationSentinel(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return compact.contains("本轮已被取消") || compact.contains("任务已取消")
    }

    /// 模型通道恢复后续跑被挂起的独立运行(从中断处 continueLoop + 复用收尾)。
    func resumeSuspendedAutonomousIfNeeded() async {
        guard let recordID = suspendedAutonomousRecordID, let session = autonomousSessionHolder else { return }
        suspendedAutonomousRecordID = nil
        suspendedAutonomousReason = nil
        updateAutonomousRun(phase: .running, statusLine: "模型通道恢复,自动续跑中。")
        if let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) { taskExecutionRecords[idx].status = .running }
        let baseline = currentArtifactCount(recordID)
        var result = await session.continueLoop()
        result = await verifyAndContinue(session: session, result: result, userRequest: autonomousRun.objective, taskRecordID: recordID, artifactBaseline: baseline)
        if case .interrupted(let reason) = result {
            suspendedAutonomousRecordID = recordID
            suspendedAutonomousReason = reason
            return
        }  // 还连不上,留挂起
        await finishAutonomousRun(result: result, recordID: recordID)
    }

    func updateAutonomousRun(phase: LingShuAutonomousRunPhase, statusLine: String) {
        var run = autonomousRun
        run.phase = phase
        run.updatedAt = Date()
        run.statusLine = statusLine
        autonomousRun = run
    }

    func completeAutonomousRunbookSteps() {
        guard var runbook = autonomousRun.runbook else { return }
        for index in runbook.steps.indices where runbook.steps[index].status != .blocked {
            runbook.steps[index].status = .completed
        }
        var run = autonomousRun
        run.runbook = runbook
        autonomousRun = run
    }
}
