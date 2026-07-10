import Foundation

@MainActor
extension LingShuState {
    /// A model may stop after echoing "long command running" even though the hosted process is
    /// still doing the actual work. Finite long commands are task dependencies, so the host waits
    /// for their real terminal state and resumes the same agent session with that evidence.
    func continueAfterAwaitedLongCommands(
        session: any LingShuAgentSessioning,
        result initial: LingShuAgentRunResult,
        taskRecordID: String?
    ) async -> LingShuAgentRunResult {
        guard Self.canContinueAfterLongCommand(initial), let recordID = taskRecordID else { return initial }

        var result = initial
        var continuationRound = 0
        while Self.canContinueAfterLongCommand(result) {
            let tracked = awaitedLongCommandJobIDsByRecord[recordID] ?? []
            guard !tracked.isEmpty else { return result }

            let snapshots = tracked.compactMap { longCommandRegistry.snapshot(id: $0) }
            let availableIDs = Set(snapshots.map(\.id))
            let missing = tracked.subtracting(availableIDs)
            if !missing.isEmpty {
                awaitedLongCommandJobIDsByRecord[recordID]?.subtract(missing)
            }
            guard !availableIDs.isEmpty else { return result }
            let running = snapshots.filter { !$0.status.isTerminal }
            if !running.isEmpty {
                let labels = running.map(\.label).joined(separator: "、")
                appendTrace(
                    kind: .tool,
                    actor: "长命令",
                    title: "等待真实终态",
                    detail: "模型尝试收尾，但仍有 \(running.count) 个托管作业运行中：\(labels)"
                )
                appendTaskRecordMessage(
                    recordID,
                    actor: "长命令",
                    role: "等待终态",
                    kind: .agent,
                    text: "检测到模型提前收尾；宿主将等待 \(running.count) 个长命令真实结束，再自动继续原任务。"
                )
                missionTitle = "等待长命令"
                missionStatus = String("正在等待：\(labels)".prefix(120))
            }

            var lastHeartbeatAt = Date.distantPast
            while true {
                if Task.isCancelled || batchInterruptRequested { return result }
                let latest = availableIDs.compactMap { longCommandRegistry.snapshot(id: $0) }
                if latest.count == availableIDs.count, latest.allSatisfy({ $0.status.isTerminal }) { break }
                if Date().timeIntervalSince(lastHeartbeatAt) >= 5 {
                    lastHeartbeatAt = Date()
                    let active = latest.filter { !$0.status.isTerminal }
                    let summary = active.map { "\($0.label) \(Self.formatElapsed($0.durationSeconds))" }.joined(separator: "；")
                    recordModelHeartbeat(source: "长命令", detail: summary, isSynthetic: true)
                    refreshTaskThreadHeartbeat(recordID: recordID, phase: .executing, summary: "等待长命令：\(summary)")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            let terminal = availableIDs.compactMap { longCommandRegistry.snapshot(id: $0) }
            for id in availableIDs { removeAwaitedLongCommand(id, recordID: recordID) }
            for snapshot in terminal {
                appendTaskRecordMessage(
                    recordID,
                    actor: "长命令",
                    role: snapshot.status == .succeeded ? "已完成" : "已结束",
                    kind: snapshot.status == .succeeded ? .result : .warning,
                    text: "\(snapshot.label)：\(snapshot.status.rawValue)，退出码 \(snapshot.exitCode.map(String.init) ?? "-")。",
                    detail: .toolResult(
                        tool: "check_long_command",
                        success: snapshot.status == .succeeded,
                        output: snapshot.modelText
                    )
                )
            }

            continuationRound += 1
            let evidence = terminal.map(\.modelText).joined(separator: "\n\n")
            appendTrace(
                kind: .route,
                actor: "长命令",
                title: "终态回灌并续跑",
                detail: "第 \(continuationRound) 次把托管作业终态回灌原会话。"
            )
            result = await session.resume("""
            【宿主托管长命令已到终态，继续原任务】
            你刚才在长命令仍运行时尝试收尾，宿主没有把“运行中”当成交付。下面是真实终态和日志；请据此继续完成原始目标。若失败，分析并修复后重试；若成功，读取实际产出并完成剩余步骤与最终交付。不要只复述状态。

            \(evidence)
            """)
            if case .interrupted = result { return result }
        }
        return result
    }

    func removeAwaitedLongCommand(_ jobID: String, recordID: String) {
        awaitedLongCommandJobIDsByRecord[recordID]?.remove(jobID)
        if awaitedLongCommandJobIDsByRecord[recordID]?.isEmpty == true {
            awaitedLongCommandJobIDsByRecord[recordID] = nil
        }
    }

    nonisolated static func canContinueAfterLongCommand(_ result: LingShuAgentRunResult) -> Bool {
        switch result {
        case .completed, .maxTurnsReached: return true
        case .blocked, .interrupted: return false
        }
    }
}
