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
        var run = autonomousRun
        run.phase = .running
        run.startedAt = run.startedAt ?? Date()
        run.updatedAt = Date()
        run.statusLine = "已授权，独立运行开始。"
        if var runbook = run.runbook,
           let index = runbook.steps.firstIndex(where: { $0.status == .waiting }) {
            runbook.steps[index].status = .running
            run.runbook = runbook
        }
        autonomousRun = run
        enterCoreState(.executing)
        missionTitle = "独立运行中"
        missionStatus = "我会按动态 runbook 自主推进，并保留暂停、继续和停止接管。"
        resetAgentRuntime(title: "独立运行中", status: "能力节点将按本轮 runbook 动态参与。")
        appendTrace(kind: .runtime, actor: "独立运行", title: "授权执行", detail: autonomousRun.statusLine)
    }

    func pauseAutonomousRun() {
        guard autonomousRun.phase == .running else { return }
        var run = autonomousRun
        run.phase = .paused
        run.updatedAt = Date()
        run.statusLine = "已暂停，等待继续或停止。"
        autonomousRun = run
        missionTitle = "独立运行已暂停"
        missionStatus = "我已停止推进，保留当前 runbook 和上下文。"
        enterCoreState(.standby, resetTimer: false)
        appendTrace(kind: .warning, actor: "用户", title: "暂停独立运行", detail: run.statusLine)
    }

    func resumeAutonomousRun() {
        guard autonomousRun.phase == .paused else { return }
        authorizeAutonomousRun()
        appendTrace(kind: .runtime, actor: "独立运行", title: "继续运行", detail: "已从暂停态恢复。")
    }

    func stopAutonomousRun() {
        guard autonomousRun.phase != .idle else { return }
        let previousObjective = autonomousRun.objective
        autonomousRun = .idle
        missionTitle = "待机中"
        missionStatus = "独立运行已停止。"
        enterCoreState(.standby, resetTimer: false)
        resetAgentRuntime()
        appendTrace(kind: .warning, actor: "用户", title: "停止独立运行", detail: previousObjective)
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
        taskRecordID: String?,
        memoryContext: MainThreadMemoryContext
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
        let raw = rawObjective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (raw?.isEmpty == false ? raw : nil) ?? (fallback.isEmpty ? "等待用户提供独立运行目标" : fallback)
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
