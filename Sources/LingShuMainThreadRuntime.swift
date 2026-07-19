import Foundation

struct LingShuKernelHeartbeat: Equatable {
    var sessionID: String
    var sequence: Int
    var occurredAt: Date
    var uptimeSeconds: Int
    var lastPrompt: String
    var contextSummary: String

    var displayText: String {
        "上次 \(formatClock(occurredAt))"
    }

    var traceDetail: String {
        let prompt = lastPrompt.isEmpty ? "暂无用户指令" : lastPrompt
        return "session=\(sessionID.prefix(8))；uptime=\(formatElapsed(uptimeSeconds))；最近指令：\(prompt)；上下文：\(contextSummary)"
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct LingShuKernelBootReport: Equatable {
    var isColdStart: Bool
    var sessionID: String
    var statusText: String
    var memoryStatus: String
    var heartbeatText: String
    var recoveredTaskSummary: String?
}

struct LingShuKernelSnapshot: Codable, Equatable {
    var sessionID: String
    var bootedAt: Date
    var lastHeartbeatAt: Date
    var heartbeatSequence: Int
    var lastPrompt: String
    var hotContextSummary: String
    var activeTaskID: String?
    var activeTaskSummary: String?
    var lastRouteSummary: String?
    var lastExecutionSummary: String?
    var coldStartCount: Int
    var updatedAt: Date
}

final class LingShuMainThreadKernel {
    private let defaults: UserDefaults
    private let snapshotKey: String
    private let heartbeatInterval: TimeInterval
    private(set) var snapshot: LingShuKernelSnapshot
    private(set) var bootReport: LingShuKernelBootReport
    private var lastReportedHeartbeatAt: Date

    init(
        defaults: UserDefaults = LingShuRuntimeEnvironment.preferences,
        snapshotKey: String = "lingshu.main-thread.kernel.snapshot",
        heartbeatInterval: TimeInterval = 20,
        now: Date = Date()
    ) {
        self.defaults = defaults
        self.snapshotKey = snapshotKey
        self.heartbeatInterval = heartbeatInterval

        let previous = Self.loadSnapshot(defaults: defaults, key: snapshotKey)
        let restored = previous.flatMap { Self.isRestorable($0, now: now) ? $0 : nil }
        let sessionID = restored?.sessionID ?? UUID().uuidString
        let coldStartCount = (previous?.coldStartCount ?? 0) + 1

        self.snapshot = .init(
            sessionID: sessionID,
            bootedAt: now,
            lastHeartbeatAt: now,
            heartbeatSequence: 0,
            lastPrompt: restored?.lastPrompt ?? "",
            hotContextSummary: restored?.hotContextSummary ?? "主线程刚完成程序级冷启动，等待第一条指令。",
            activeTaskID: restored?.activeTaskID,
            activeTaskSummary: restored?.activeTaskSummary,
            lastRouteSummary: restored?.lastRouteSummary,
            lastExecutionSummary: restored?.lastExecutionSummary,
            coldStartCount: coldStartCount,
            updatedAt: now
        )
        self.lastReportedHeartbeatAt = now

        let recovered = restored?.activeTaskSummary ?? restored?.hotContextSummary
        self.bootReport = .init(
            isColdStart: restored == nil,
            sessionID: sessionID,
            statusText: restored == nil ? "主线程冷启动完成，等待用户指令。" : "主线程已从快照恢复，继续沿用上一轮上下文。",
            memoryStatus: restored == nil ? "主线程冷启动" : "已恢复主线程快照",
            heartbeatText: "上次 --:--:--",
            recoveredTaskSummary: recovered
        )

        persist()
    }

    func receiveUserPrompt(_ prompt: String, memoryStatus: String) -> LingShuKernelHeartbeat {
        snapshot.lastPrompt = prompt
        snapshot.hotContextSummary = "收到用户指令，已检索主线程记忆。\(memoryStatus)"
        snapshot.lastRouteSummary = nil
        snapshot.updatedAt = Date()
        persist()
        return heartbeat(force: true) ?? currentHeartbeat()
    }

    func observeMemoryStatus(prompt: String, status: String) {
        snapshot.lastPrompt = prompt
        snapshot.hotContextSummary = "主线程记忆检索完成。\(status)"
        snapshot.updatedAt = Date()
        persist()
    }

    func observeDirectAnswer(prompt: String, answer: String) {
        snapshot.lastPrompt = prompt
        snapshot.hotContextSummary = "本轮由主线程直接回答：\(Self.compact(answer, limit: 180))"
        snapshot.activeTaskID = nil
        snapshot.activeTaskSummary = nil
        snapshot.lastRouteSummary = "无需创建任务线程。"
        snapshot.updatedAt = Date()
        persist()
    }

    func observeRoute(prompt: String, routeSummary: String, needsAgents: Bool, agents: [String]) {
        snapshot.lastPrompt = prompt
        snapshot.lastRouteSummary = routeSummary
        if needsAgents {
            let taskID = snapshot.activeTaskID ?? "task-\(Int(Date().timeIntervalSince1970))"
            snapshot.activeTaskID = taskID
            let agentText = agents.isEmpty ? "未列明" : agents.joined(separator: "、")
            snapshot.activeTaskSummary = "任务线程 \(taskID)：\(Self.compact(prompt, limit: 120))；参与 agent：\(agentText)。"
            snapshot.hotContextSummary = "主线程已完成判断并创建/续接任务线程：\(agentText)。"
        } else {
            snapshot.hotContextSummary = "主线程判断本轮无需任务线程：\(Self.compact(routeSummary, limit: 160))"
            snapshot.activeTaskID = nil
            snapshot.activeTaskSummary = nil
        }
        snapshot.updatedAt = Date()
        persist()
    }

    func observeExecution(prompt: String, summary: String, completed: Bool) {
        snapshot.lastPrompt = prompt
        snapshot.lastExecutionSummary = Self.compact(summary, limit: 260)
        snapshot.hotContextSummary = completed
            ? "执行线程已回传并由主线程收束：\(Self.compact(summary, limit: 160))"
            : "执行线程受阻：\(Self.compact(summary, limit: 160))"
        if completed {
            snapshot.activeTaskSummary = snapshot.hotContextSummary
        }
        snapshot.updatedAt = Date()
        persist()
    }

    func observeTaskThreadCommit(_ commit: LingShuTaskThreadCommit) {
        let compactLine = Self.compact(commit.ledgerLine, limit: 260)
        snapshot.lastExecutionSummary = compactLine
        if commit.isOpen {
            snapshot.activeTaskID = commit.taskId
            snapshot.activeTaskSummary = compactLine
            snapshot.hotContextSummary = "任务线程已提交运行态：\(Self.compact(commit.progressSummary, limit: 160))"
        } else {
            if snapshot.activeTaskID == commit.taskId {
                snapshot.activeTaskID = nil
                snapshot.activeTaskSummary = nil
            }
            snapshot.hotContextSummary = "任务线程已收束：\(Self.compact(commit.progressSummary, limit: 160))"
        }
        snapshot.updatedAt = Date()
        persist()
    }

    func promptHint(baseMemory: String) -> String {
        """
        主线程常驻快照：
        - session: \(snapshot.sessionID)
        - 本次程序冷启动次数: \(snapshot.coldStartCount)
        - 最近用户指令: \(snapshot.lastPrompt.isEmpty ? "暂无" : snapshot.lastPrompt)
        - 热上下文: \(snapshot.hotContextSummary)
        - 当前任务线程: \(snapshot.activeTaskSummary ?? "未创建或已收束")
        - 最近路由: \(snapshot.lastRouteSummary ?? "暂无")
        - 最近执行: \(snapshot.lastExecutionSummary ?? "暂无")

        记忆检索结果：
        \(baseMemory)
        """
    }

    func heartbeat(force: Bool = false, now: Date = Date()) -> LingShuKernelHeartbeat? {
        guard force || now.timeIntervalSince(lastReportedHeartbeatAt) >= heartbeatInterval else {
            return nil
        }

        snapshot.heartbeatSequence += 1
        snapshot.lastHeartbeatAt = now
        snapshot.updatedAt = now
        lastReportedHeartbeatAt = now
        persist()
        return currentHeartbeat(now: now)
    }

    private func currentHeartbeat(now: Date = Date()) -> LingShuKernelHeartbeat {
        .init(
            sessionID: snapshot.sessionID,
            sequence: snapshot.heartbeatSequence,
            occurredAt: now,
            uptimeSeconds: max(0, Int(now.timeIntervalSince(snapshot.bootedAt))),
            lastPrompt: Self.compact(snapshot.lastPrompt, limit: 80),
            contextSummary: Self.compact(snapshot.hotContextSummary, limit: 120)
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    private static func loadSnapshot(defaults: UserDefaults, key: String) -> LingShuKernelSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LingShuKernelSnapshot.self, from: data)
    }

    private static func isRestorable(_ snapshot: LingShuKernelSnapshot, now: Date) -> Bool {
        now.timeIntervalSince(snapshot.updatedAt) <= 7 * 24 * 60 * 60
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "\(trimmed.prefix(limit))..."
    }
}
