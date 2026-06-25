import Foundation

@MainActor
extension LingShuState {
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
        let recordID = taskRecordID ?? createTaskExecutionRecord(for: prompt)

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

        appendTaskRecordMessage(recordID, actor: "独立运行", role: "环境检测", kind: .core, text: snapshot.environment?.summaryLine ?? "环境检测完成")
        appendTaskRecordMessage(recordID, actor: "独立运行", role: "动态规划", kind: .router, text: snapshot.runbook?.summaryLine ?? "动态规划完成")
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "中枢", kind: .result, text: response)
        applyTaskRecordRoute(
            recordID,
            route: .init(
                needsAgents: false,
                agents: [],
                directAnswer: response,
                finalAnswer: response,
                summary: "进入独立运行模式，已完成环境检测、自检和动态 runbook。"
            )
        )
        finishTaskRecord(recordID, status: snapshot.phase == .blocked ? .blocked : .answered, summary: response)
        chatMessages.append(.init(speaker: "灵枢", text: response, isUser: false, taskRecordID: recordID))
        rememberMainThreadTurn(prompt: prompt, reply: response)
        return response
    }

    func autonomousEnvironmentInput() -> LingShuAutonomousEnvironmentInput {
        .init(
            workingDirectory: agentWorkingDirectory,
            modelProvider: modelProvider,
            modelName: modelName,
            isModelConnected: isModelConnected,
            modelConnectionState: modelConnectionState,
            executionPermissionMode: executionPermissionMode,
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

    func normalizedAutonomousObjective(from rawObjective: String?) -> String {
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

    func isAutonomousRunCommand(_ prompt: String) -> Bool {
        let normalized = normalizeMemoryText(prompt)
        let modeSignals = ["独立运行模式", "独立运行", "自主运行", "托管模式", "autopilot"]
        let actionSignals = ["进入", "启动", "开启", "准备", "开始"]
        return modeSignals.contains { normalized.contains($0) }
            && actionSignals.contains { normalized.contains($0) }
    }
}
