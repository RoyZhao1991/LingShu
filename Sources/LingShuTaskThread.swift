import Foundation

enum LingShuTaskThreadStatus: String, Codable, Equatable {
    case queued = "排队中"
    case planning = "规划中"
    case restored = "已恢复"
    case executing = "执行中"
    case delivered = "已交付"
    case blocked = "已阻断"
}

enum LingShuTaskSegmentStatus: String, Codable, Equatable {
    case waiting = "等待中"
    case running = "执行中"
    case completed = "已完成"
    case blocked = "已阻断"
}

struct LingShuTaskSegment: Identifiable, Codable, Equatable {
    let id: String
    let recordID: String
    let prompt: String
    var status: LingShuTaskSegmentStatus
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    static func create(recordID: String, prompt: String, status: LingShuTaskSegmentStatus = .waiting, now: Date = Date()) -> LingShuTaskSegment {
        .init(
            id: "segment-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))",
            recordID: recordID,
            prompt: prompt,
            status: status,
            createdAt: now,
            startedAt: status == .running ? now : nil,
            completedAt: nil
        )
    }
}

struct LingShuTaskThread: Identifiable, Codable, Equatable {
    let id: String
    var fingerprint: String
    var prompt: String
    var summary: String
    var status: LingShuTaskThreadStatus
    var participatingAgents: [String]
    var permissionBoundary: String
    var memoryStatus: String
    var segments: [LingShuTaskSegment]
    var createdAt: Date
    var updatedAt: Date

    var queuedSegmentCount: Int {
        segments.filter { $0.status == .waiting }.count
    }

    var runningSegmentCount: Int {
        segments.filter { $0.status == .running }.count
    }

    var hasRunningSegment: Bool {
        runningSegmentCount > 0 || status == .planning || status == .restored || status == .executing
    }

    var hasQueuedSegments: Bool {
        queuedSegmentCount > 0
    }

    var displayTitle: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 18 else { return trimmed.isEmpty ? id : trimmed }
        return "\(trimmed.prefix(18))..."
    }

    static func create(
        id: String,
        fingerprint: String? = nil,
        prompt: String,
        memoryStatus: String,
        restored: Bool,
        recordID: String? = nil,
        now: Date = Date()
    ) -> LingShuTaskThread {
        let initialSegments = recordID.map {
            [LingShuTaskSegment.create(recordID: $0, prompt: prompt, status: .running, now: now)]
        } ?? []
        return .init(
            id: id,
            fingerprint: fingerprint ?? LingShuTaskThreadScheduler.fingerprint(for: prompt, restoredTaskID: restored ? id : nil),
            prompt: prompt,
            summary: restored ? "主线程命中历史任务，已恢复任务线程。" : "主线程判断需要协作，已创建任务线程。",
            status: restored ? .restored : .planning,
            participatingAgents: [],
            permissionBoundary: "待裁决",
            memoryStatus: memoryStatus,
            segments: initialSegments,
            createdAt: now,
            updatedAt: now
        )
    }

    mutating func applyRoute(summary: String, agents: [String], permissionBoundary: String) {
        self.summary = summary
        self.participatingAgents = agents
        self.permissionBoundary = permissionBoundary
        self.status = .planning
        self.updatedAt = Date()
    }

    mutating func markExecuting(permissionBoundary: String) {
        self.permissionBoundary = permissionBoundary
        self.status = .executing
        markLatestWaitingSegmentRunning()
        self.updatedAt = Date()
    }

    mutating func markDelivered(summary: String) {
        self.summary = summary
        self.status = .delivered
        markRunningSegments(.completed)
        self.updatedAt = Date()
    }

    mutating func markBlocked(reason: String) {
        self.summary = reason
        self.status = .blocked
        markRunningSegments(.blocked)
        self.updatedAt = Date()
    }

    mutating func enqueue(recordID: String, prompt: String, now: Date = Date()) {
        segments.append(.create(recordID: recordID, prompt: prompt, status: .waiting, now: now))
        status = hasRunningSegment ? status : .queued
        updatedAt = now
    }

    mutating func start(recordID: String, prompt: String, now: Date = Date()) {
        if let index = segments.firstIndex(where: { $0.recordID == recordID }) {
            segments[index].status = .running
            segments[index].startedAt = now
        } else {
            segments.append(.create(recordID: recordID, prompt: prompt, status: .running, now: now))
        }
        self.prompt = prompt
        if status == .queued || status == .delivered || status == .blocked {
            status = .planning
        }
        updatedAt = now
    }

    mutating func complete(recordID: String, blocked: Bool = false, now: Date = Date()) {
        for index in segments.indices where segments[index].recordID == recordID {
            segments[index].status = blocked ? .blocked : .completed
            segments[index].completedAt = now
        }
        if queuedSegmentCount > 0 {
            status = hasRunningSegment ? status : .queued
        } else if blocked {
            status = .blocked
        } else {
            status = .delivered
        }
        updatedAt = now
    }

    mutating func popNextWaitingSegment(now: Date = Date()) -> LingShuTaskSegment? {
        guard let index = segments.firstIndex(where: { $0.status == .waiting }) else { return nil }
        segments[index].status = .running
        segments[index].startedAt = now
        prompt = segments[index].prompt
        status = .planning
        updatedAt = now
        return segments[index]
    }

    private mutating func markLatestWaitingSegmentRunning(now: Date = Date()) {
        guard !segments.contains(where: { $0.status == .running }),
              let index = segments.lastIndex(where: { $0.status == .waiting }) else { return }
        segments[index].status = .running
        segments[index].startedAt = now
    }

    private mutating func markRunningSegments(_ status: LingShuTaskSegmentStatus, now: Date = Date()) {
        for index in segments.indices where segments[index].status == .running {
            segments[index].status = status
            segments[index].completedAt = now
        }
    }
}

enum LingShuTaskSubmissionAction: Equatable {
    case startForeground
    case startParallel
    case enqueueSameThread
    case enqueueUntilCapacity
}

struct LingShuTaskSubmissionDecision: Equatable {
    var action: LingShuTaskSubmissionAction
    var threadID: String
    var fingerprint: String
    var reason: String

    var startsImmediately: Bool {
        action == .startForeground || action == .startParallel
    }
}

struct LingShuTaskThreadScheduler {
    var maxParallelThreads: Int = 3

    func decide(
        prompt: String,
        memoryLookup: LingShuTaskMemoryLookup,
        activeThreads: [LingShuTaskThread],
        focusedThread: LingShuTaskThread?,
        hasForegroundCall: Bool
    ) -> LingShuTaskSubmissionDecision {
        let restoredTaskID = memoryLookup.restored ? memoryLookup.taskID : nil
        let fingerprint = Self.fingerprint(for: prompt, restoredTaskID: restoredTaskID)
        let runningThreads = activeThreads.filter { $0.hasRunningSegment }

        // 同线程命中：要么话题指纹一致，要么记忆「高置信」续接到该 taskID。
        // 不再用任意 memoryLookup.taskID（中/无置信时它是模糊匹配或新鲜 id），
        // 否则会把无关请求静默并进运行中的任务。
        if let sameThread = activeThreads.first(where: { $0.fingerprint == fingerprint || (restoredTaskID != nil && $0.id == restoredTaskID) }) {
            let action: LingShuTaskSubmissionAction = sameThread.hasRunningSegment ? .enqueueSameThread : (hasForegroundCall ? .startParallel : .startForeground)
            return .init(
                action: action,
                threadID: sameThread.id,
                fingerprint: sameThread.fingerprint,
                reason: sameThread.hasRunningSegment ? "命中同一任务线程，本段进入顺序队列。" : "命中历史任务线程，可直接续接。"
            )
        }

        if let focusedThread, isLikelyContinuation(prompt, focusedThread: focusedThread) {
            return .init(
                action: focusedThread.hasRunningSegment ? .enqueueSameThread : (hasForegroundCall ? .startParallel : .startForeground),
                threadID: focusedThread.id,
                fingerprint: focusedThread.fingerprint,
                reason: "表达包含续写/调整信号，按当前焦点任务的下一段处理。"
            )
        }

        if !hasForegroundCall {
            return .init(
                action: .startForeground,
                threadID: memoryLookup.taskID,
                fingerprint: fingerprint,
                reason: "当前没有前台模型调用，作为焦点任务启动。"
            )
        }

        if runningThreads.count < maxParallelThreads {
            return .init(
                action: .startParallel,
                threadID: memoryLookup.taskID,
                fingerprint: fingerprint,
                reason: "与当前任务上下文可隔离，创建并行任务线程。"
            )
        }

        return .init(
            action: .enqueueUntilCapacity,
            threadID: memoryLookup.taskID,
            fingerprint: fingerprint,
            reason: "并行线程数已达上限，先进入等待队列。"
        )
    }

    /// 话题信号词 → 话题标记。指纹归一与「续接话题绑定」共用同一张表。
    private static let topicSignals: [(String, String)] = [
        ("ppt", "ppt"), ("幻灯片", "ppt"), ("演示文稿", "ppt"), ("汇报", "presentation"),
        ("爬虫", "crawler"), ("web", "web"), ("网页", "web"), ("app", "app"),
        ("语音", "voice"), ("音频", "voice"), ("视觉", "vision"), ("摄像头", "vision"),
        ("架构", "architecture"), ("代码", "code"), ("测试", "test"), ("修复", "fix"),
        ("灵枢", "lingshu"), ("安全票夹", "receipt-vault")
    ]

    /// 从文本中抽出话题标记集合。
    static func topicTokens(from text: String) -> Set<String> {
        let normalized = normalize(text)
        return Set(topicSignals.compactMap { normalized.contains($0.0) ? $0.1 : nil })
    }

    /// 从「topic-a-b」指纹反解出话题标记集合（非话题指纹返回空集，不会误匹配）。
    static func topicTokens(fromFingerprint fingerprint: String) -> Set<String> {
        guard fingerprint.hasPrefix("topic-") else { return [] }
        let body = fingerprint.dropFirst("topic-".count)
        return Set(body.split(separator: "-").map(String.init))
    }

    static func fingerprint(for prompt: String, restoredTaskID: String? = nil) -> String {
        if let restoredTaskID, !restoredTaskID.isEmpty {
            return restoredTaskID
        }

        let matched = topicTokens(from: prompt)
        if !matched.isEmpty {
            return "topic-\(matched.sorted().joined(separator: "-"))"
        }

        let trimmed = normalize(prompt)
            .replacingOccurrences(of: "帮我", with: "")
            .replacingOccurrences(of: "给我", with: "")
            .replacingOccurrences(of: "做一个", with: "")
            .replacingOccurrences(of: "写一个", with: "")
        return "topic-\(trimmed.prefix(18))"
    }

    /// 是否为「续接焦点任务」。修复误路由的核心：不再让裸连接词把无关任务吞进焦点线程。
    /// 续接成立须满足其一：
    /// ① 明确回指上一产物/历史任务（强信号）；
    /// ② 短小省略式追问（≤14 字）带编辑/连接信号——这类话本身没有完整话题，归焦点任务；
    /// ③ 带编辑信号且与焦点任务话题指纹有重叠（长请求也算续接）。
    /// 长、自带完整且不同话题的全新请求（如把 PPT 任务里突然插入的音频自检需求）一律不算续接。
    private func isLikelyContinuation(_ prompt: String, focusedThread: LingShuTaskThread?) -> Bool {
        let normalized = Self.normalize(prompt)

        let backReferenceAnchors = [
            "刚才", "上一个", "上一版", "上次", "之前那", "前面那",
            "那个任务", "这个任务", "这个项目", "原来的", "这版", "接着上"
        ]
        if backReferenceAnchors.contains(where: { normalized.contains($0) }) {
            return true
        }

        let weakSignals = ["继续", "再", "然后", "接着", "优化", "调整", "修改", "补充", "迭代", "改一下", "加上", "去掉"]
        guard weakSignals.contains(where: { normalized.contains($0) }) else { return false }

        // 短省略式追问：归焦点任务。
        if normalized.count <= 14 { return true }

        // 长请求：必须与焦点任务话题重叠才算续接，否则视为新任务（隔离推进）。
        if let focusedThread {
            let promptTopics = Self.topicTokens(from: normalized)
            let focusedTopics = Self.topicTokens(fromFingerprint: focusedThread.fingerprint)
            if !promptTopics.isEmpty, !promptTopics.isDisjoint(with: focusedTopics) {
                return true
            }
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
