import Foundation

/// 每线程隔离执行状态(Layer ③ 地基)。
///
/// 替换全局单飞状态(`isModelReplying`/`isModelExecuting` bool、单个 `taskRuntime`):
/// 每条任务线程拥有自己的执行阶段、模型在飞标志、心跳与起止时间,互不踩踏——这是「真并行」的前提。
enum LingShuThreadExecutionPhase: String, Codable, Equatable, Sendable {
    case routing = "路由中"
    case replying = "作答中"
    case executing = "执行中"
    case reviewing = "验收中"
    case delivered = "已交付"
    case blocked = "已阻断"
}

struct LingShuThreadExecutionState: Identifiable, Equatable, Sendable {
    let threadID: String
    var phase: LingShuThreadExecutionPhase
    var summary: String
    var startedAt: Date?
    var lastHeartbeatAt: Date?
    /// 本线程是否有模型调用在飞(替代全局 isModelReplying/isModelExecuting)。
    var isModelInFlight: Bool

    var id: String { threadID }

    init(
        threadID: String,
        phase: LingShuThreadExecutionPhase = .routing,
        summary: String = "",
        startedAt: Date? = Date(),
        lastHeartbeatAt: Date? = Date(),
        isModelInFlight: Bool = false
    ) {
        self.threadID = threadID
        self.phase = phase
        self.summary = summary
        self.startedAt = startedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.isModelInFlight = isModelInFlight
    }
}

/// 有界并发管理器:同时最多 `maxConcurrent` 条线程真并行,超出排队。
/// 纯值类型,便于单测;由 LingShuState 作为 @Published 持有以驱动 UI(N 张并发任务卡)。
struct LingShuConcurrencyManager: Equatable, Sendable {
    var maxConcurrent: Int
    private(set) var active: [LingShuThreadExecutionState]
    /// 排队中的线程 id(FIFO)。
    private(set) var waiting: [String]

    init(maxConcurrent: Int = 3) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.active = []
        self.waiting = []
    }

    var runningCount: Int { active.count }
    var waitingCount: Int { waiting.count }
    var hasCapacity: Bool { active.count < maxConcurrent }

    /// 是否有任意线程的模型调用在飞(按线程聚合,取代全局 hasActiveModelCall)。
    var anyModelInFlight: Bool { active.contains { $0.isModelInFlight } }

    func state(for threadID: String) -> LingShuThreadExecutionState? {
        active.first { $0.threadID == threadID }
    }

    func isRunning(_ threadID: String) -> Bool {
        active.contains { $0.threadID == threadID }
    }

    func isWaiting(_ threadID: String) -> Bool {
        waiting.contains(threadID)
    }

    /// 申请执行一条线程:已在跑→true;有容量→立即纳入(running)返回 true;否则入队返回 false。
    @discardableResult
    mutating func requestAdmission(threadID: String, summary: String = "") -> Bool {
        if isRunning(threadID) { return true }
        if hasCapacity {
            waiting.removeAll { $0 == threadID }
            active.append(.init(threadID: threadID, summary: summary))
            return true
        }
        if !waiting.contains(threadID) { waiting.append(threadID) }
        return false
    }

    mutating func updateState(threadID: String, _ mutate: (inout LingShuThreadExecutionState) -> Void) {
        guard let index = active.firstIndex(where: { $0.threadID == threadID }) else { return }
        mutate(&active[index])
    }

    mutating func setModelInFlight(_ inFlight: Bool, threadID: String) {
        updateState(threadID: threadID) { $0.isModelInFlight = inFlight }
    }

    mutating func heartbeat(threadID: String, now: Date = Date()) {
        updateState(threadID: threadID) { $0.lastHeartbeatAt = now }
    }

    /// 完成/移除一条线程,并在有容量时自动纳入下一条排队线程;返回被纳入的线程 id(无则 nil)。
    @discardableResult
    mutating func complete(threadID: String) -> String? {
        active.removeAll { $0.threadID == threadID }
        waiting.removeAll { $0 == threadID }
        guard hasCapacity, !waiting.isEmpty else { return nil }
        let next = waiting.removeFirst()
        active.append(.init(threadID: next))
        return next
    }
}
