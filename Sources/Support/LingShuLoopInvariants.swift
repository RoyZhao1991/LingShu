import Foundation

/// 循环不变量(差距1·架网,2026-06-21):agent 循环在回合边界必须恒满足的一组**全局不变量**。
///
/// 思路是"消灭一类 bug,而非补一个实例":历史上反复出现的根因(孤儿 tool 结果 → 网关 400、
/// 阻塞/打断标志粘滞泄漏旁路验收、tool_calls 后没补结果)都是同一类——**回合边界上下文不良构 / 状态标志不一致**。
/// 把它们做成**纯逻辑可单测的不变量 + 循环在边界调用记录**,让整类 bug 在设计上不可能漏过。
///
/// 设计取舍:**软断言不 trap**——违反只**记录**(会话内列表供 fuzz 精确断言 + 全局遥测计数供 soak/MCP 暴露),
/// 生产里绝不因不变量违反崩 app(agent 循环崩了比一条不良构历史更糟);**单测/fuzz 才是硬闸**。
/// 通用、零定制:只看循环结构(消息配对/标志一致/历史预算),不碰任何业务/领域。

// MARK: - 边界 / 终态种类

/// 检查时机(回合边界)。
enum LingShuLoopBoundary: Sendable, Equatable {
    /// send 入口:压缩/裁剪 + 追加用户输入之后(此刻历史应在预算内且良构)。
    case afterCompaction
    /// 每次调用模型前(循环 while 顶):上下文必须是良构 OpenAI 序列、无未应答的 tool_call。
    case beforeModelCall
    /// runLoop 返回后(在 send/resume/continueLoop 里、`defer isRunning=false` 已生效时):状态标志与结果一致。
    case terminal(LingShuLoopTerminalKind)
}

/// 终态种类(与 `LingShuAgentRunResult` 对应但解耦,便于纯逻辑构造测试)。
enum LingShuLoopTerminalKind: String, Sendable, Equatable {
    case completed, blocked, maxTurnsReached, interrupted

    init(_ result: LingShuAgentRunResult) {
        switch result {
        case .completed: self = .completed
        case .blocked: self = .blocked
        case .maxTurnsReached: self = .maxTurnsReached
        case .interrupted: self = .interrupted
        }
    }
}

// MARK: - 违反码(结构化遥测)

/// 不变量违反(原因码)。`Equatable` 便于单测精确断言"抓到了哪条"。
enum LingShuLoopInvariantViolation: Equatable, Sendable, CustomStringConvertible {
    case toolResultMissingID(index: Int)                 // I1:.tool 结果缺 toolCallID
    case orphanToolResult(toolCallID: String)            // I1:.tool 结果找不到对应的更早 assistant tool_call
    case unansweredToolCall(toolCallID: String)          // I2:assistant 发起的 tool_call 没被应答(非阻塞 pending 那条)
    case runningAfterTerminal                            // I3:返回终态后 isRunning 仍为 true
    case blockStateInconsistent(pendingNil: Bool, kind: LingShuLoopTerminalKind)  // I4:阻塞标志与结果不一致
    case correctionNotConsumed(kind: LingShuLoopTerminalKind)                     // I5:.completed 时仍有未采纳的纠正
    case historyOverBudget(bodyCount: Int, window: Int)  // I6(条数压缩):压缩后非系统历史条数超预算
    case historyTokensOverBudget(tokens: Int, budget: Int)  // I6(token 压缩):压缩后非系统历史 token 超预算

    var description: String {
        switch self {
        case .toolResultMissingID(let i): return "tool结果[\(i)]缺toolCallID"
        case .orphanToolResult(let id): return "孤儿tool结果(无对应tool_call):\(id)"
        case .unansweredToolCall(let id): return "未应答tool_call:\(id)"
        case .runningAfterTerminal: return "终态后isRunning仍true"
        case .blockStateInconsistent(let nilP, let k): return "阻塞标志不一致(pendingNil=\(nilP),结果=\(k.rawValue))"
        case .correctionNotConsumed(let k): return "纠正未采纳即收尾(结果=\(k.rawValue))"
        case .historyOverBudget(let n, let w): return "历史超预算(body=\(n)>窗口\(w))"
        case .historyTokensOverBudget(let t, let b): return "历史token超预算(body≈\(t)tok>预算\(b))"
        }
    }
}

// MARK: - 循环退出原因码(差距1.3 结构化失败遥测)

/// 循环每次退出落一条结构化原因码——把"为什么停"从自然语言里解耦出来,供遥测/soak/复盘按因聚合。
enum LingShuAgentExitReason: String, Sendable, Equatable {
    case normalCompletion        // 模型给出最终答复正常收尾
    case blockedAwaitingInput    // 调用阻塞工具(ask_user)等外部输入
    case stuckHandback           // 原地打转(连续相同调用)诚实交还
    case readOnlyStallHandback   // 只读空转到顶交还
    case overValidationForced    // 过度自测空转 → 强制收尾交独立验收
    case infraInterrupted        // 基础设施中断(网络/网关不可达)
    case maxTurnsCeiling         // 撞安全天花板
    case userCancelled           // 用户停止(Task 取消)
}

// MARK: - 状态快照(纯值,便于测试构造任意"坏状态")

struct LingShuLoopStateSnapshot: Sendable {
    var messages: [LingShuAgentMessage]
    var isRunning: Bool
    var pendingBlockToolCallID: String?
    var hasPendingHumanInteraction: Bool
    var hasPendingCorrection: Bool
    var maxHistoryMessages: Int
    /// 压缩器的容量契约(差距4):非 nil 时 I6 按它(条数/token)校验;nil 时回退用 `maxHistoryMessages` 条数。
    var compactionBudget: LingShuCompactionBudget?

    init(messages: [LingShuAgentMessage], isRunning: Bool = false, pendingBlockToolCallID: String? = nil,
         hasPendingHumanInteraction: Bool = false,
         hasPendingCorrection: Bool = false, maxHistoryMessages: Int = 0,
         compactionBudget: LingShuCompactionBudget? = nil) {
        self.messages = messages
        self.isRunning = isRunning
        self.pendingBlockToolCallID = pendingBlockToolCallID
        self.hasPendingHumanInteraction = hasPendingHumanInteraction
        self.hasPendingCorrection = hasPendingCorrection
        self.maxHistoryMessages = maxHistoryMessages
        self.compactionBudget = compactionBudget
    }
}

// MARK: - 检查器(纯逻辑)

enum LingShuLoopInvariants {
    /// 历史预算松弛:压缩保留「摘要(1)+最近(window-1)」=window,send 再追加用户输入(+1),
    /// 兜底硬裁剪丢孤儿 tool 可能更少。给 2 的松弛覆盖这点,绝不误报。
    static let historyBudgetSlack = 2

    /// 运行期检查总开关(默认开;检查 O(历史长度),相对一次模型网络调用可忽略)。仅测试/调试切换,故 unsafe 即可。
    nonisolated(unsafe) static var runtimeChecksEnabled = true

    /// 核心检查:给定快照与边界,返回所有违反(空=健康)。纯函数,无副作用。
    static func check(_ s: LingShuLoopStateSnapshot, at boundary: LingShuLoopBoundary) -> [LingShuLoopInvariantViolation] {
        var v: [LingShuLoopInvariantViolation] = []
        v += checkToolPairing(s.messages, boundary: boundary, pendingBlockToolCallID: s.pendingBlockToolCallID)
        switch boundary {
        case .afterCompaction:
            v += checkHistoryBudget(messages: s.messages, maxHistoryMessages: s.maxHistoryMessages,
                                    compactionBudget: s.compactionBudget)
        case .beforeModelCall:
            break   // 此处只保证良构(配对);预算只在 send 入口压缩点保证,循环内允许 in-flight 增长
        case .terminal(let kind):
            if s.isRunning { v.append(.runningAfterTerminal) }
            v += checkBlockState(
                kind: kind,
                hasPendingBlock: s.pendingBlockToolCallID != nil || s.hasPendingHumanInteraction
            )
            if kind == .completed && s.hasPendingCorrection { v.append(.correctionNotConsumed(kind: kind)) }
        }
        return v
    }

    // MARK: I1+I2:工具调用 / 结果配对(OpenAI 协议良构状态机)

    /// 扫一遍消息:跟踪"最近一条 assistant 发起、尚未应答的 tool_call 集合(open)";
    /// 任何非 tool 消息出现、或一组新 tool_calls 出现前,open 必须清空(否则未应答);
    /// 每条 tool 结果必须能配上已声明的 tool_call(否则孤儿);收尾时仍 open 的视为未应答
    /// (唯一例外:`.blocked` 终态允许那条 pending 阻塞调用 open)。
    static func checkToolPairing(_ messages: [LingShuAgentMessage], boundary: LingShuLoopBoundary,
                                 pendingBlockToolCallID: String?) -> [LingShuLoopInvariantViolation] {
        var v: [LingShuLoopInvariantViolation] = []
        var declared = Set<String>()        // 至此所有 assistant 声明过的 tool_call id
        var answered = Set<String>()        // 已被 tool 结果应答的 id
        var openCalls: [String] = []        // 最近一组尚未应答的 id(有序)

        func flushOpenAsUnanswered() {
            for id in openCalls where !answered.contains(id) {
                v.append(.unansweredToolCall(toolCallID: id))
            }
            openCalls.removeAll()
        }

        for (i, m) in messages.enumerated() {
            switch m.role {
            case .assistant where !m.toolCalls.isEmpty:
                flushOpenAsUnanswered()   // 上一组必须已答完
                for c in m.toolCalls {
                    declared.insert(c.id)
                    openCalls.append(c.id)
                }
            case .assistant, .user, .system:
                flushOpenAsUnanswered()   // 纯文本/用户/系统消息出现 → open 必须为空
            case .tool:
                guard let id = m.toolCallID, !id.isEmpty else {
                    v.append(.toolResultMissingID(index: i)); continue
                }
                if !declared.contains(id) { v.append(.orphanToolResult(toolCallID: id)) }
                answered.insert(id)
                openCalls.removeAll { $0 == id }
            }
        }

        // 收尾:仍 open 的 = 未应答。.blocked 终态豁免那条 pending 阻塞调用。
        var allowedOpen = Set<String>()
        if case .terminal(.blocked) = boundary, let p = pendingBlockToolCallID { allowedOpen.insert(p) }
        for id in openCalls where !answered.contains(id) && !allowedOpen.contains(id) {
            v.append(.unansweredToolCall(toolCallID: id))
        }
        return v
    }

    // MARK: I4:阻塞标志一致性

    static func checkBlockState(kind: LingShuLoopTerminalKind, hasPendingBlock: Bool) -> [LingShuLoopInvariantViolation] {
        let pendingNil = !hasPendingBlock
        switch kind {
        case .blocked:
            // 阻塞终态必须有 pending 调用。
            return pendingNil ? [.blockStateInconsistent(pendingNil: true, kind: kind)] : []
        case .completed, .maxTurnsReached, .interrupted:
            // 非阻塞终态绝不能残留 pending(否则就是阻塞标志粘滞泄漏)。
            return pendingNil ? [] : [.blockStateInconsistent(pendingNil: false, kind: kind)]
        }
    }

    // MARK: I6:历史预算

    /// 非系统 body = 去掉**开头连续的系统消息**(身份/seed)后剩下的历史。中途注入的简报系统消息算 body
    /// (它们本就该随窗口滚动淘汰)。按压缩器声明的容量契约校验:
    /// - 条数压缩(经典/兜底):body 条数 ≤ window + 松弛;
    /// - token 压缩(差距4 分层):**除去单条最大消息后**(单条巨型消息无法再切,豁免)的 body token ≤ 预算×2。
    ///   这样既抓"压缩没跑→无界累积"(很多条堆出的总量),又不误伤"用户贴了一条超长文本"(单条豁免)。
    static func checkHistoryBudget(messages: [LingShuAgentMessage], maxHistoryMessages: Int,
                                   compactionBudget: LingShuCompactionBudget? = nil) -> [LingShuLoopInvariantViolation] {
        let leadingSystem = messages.prefix { $0.role == .system }.count
        let body = Array(messages[leadingSystem...])

        switch compactionBudget {
        case .tokens(let tokenBudget):
            guard tokenBudget > 0, !body.isEmpty else { return [] }
            let total = LingShuTokenEstimator.estimate(body)
            let largest = body.map { LingShuTokenEstimator.estimate($0) }.max() ?? 0
            let ceiling = tokenBudget * 2
            return (total - largest) > ceiling ? [.historyTokensOverBudget(tokens: total, budget: tokenBudget)] : []
        case .messageCount(let window):
            guard window > 0 else { return [] }
            return body.count > window + historyBudgetSlack ? [.historyOverBudget(bodyCount: body.count, window: window)] : []
        case .none:
            // 无显式契约 → 回退用 maxHistoryMessages 条数(经典内置压缩/裁剪路径)。
            guard maxHistoryMessages > 0 else { return [] }
            return body.count > maxHistoryMessages + historyBudgetSlack ? [.historyOverBudget(bodyCount: body.count, window: maxHistoryMessages)] : []
        }
    }
}

// MARK: - 全局遥测(供 soak / MCP lingshu_status 暴露,断言为 0)

/// 进程级不变量违反累计计数。从 actor 上下文累加、从 MainActor 读取,故用锁保护。
/// 这是"网先在、持续守"的对外信号:soak/真机长跑断言它恒为 0,回归即告警。
enum LingShuLoopInvariantTelemetry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _total = 0
    nonisolated(unsafe) private static var _lastSamples: [String] = []   // 最近若干条违反摘要(诊断用,有上限)

    static var total: Int { lock.lock(); defer { lock.unlock() }; return _total }
    static var lastSamples: [String] { lock.lock(); defer { lock.unlock() }; return _lastSamples }

    static func record(_ violations: [LingShuLoopInvariantViolation], boundary: LingShuLoopBoundary) {
        guard !violations.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        _total += violations.count
        for vio in violations {
            _lastSamples.append("\(vio)@\(boundary)")
            if _lastSamples.count > 32 { _lastSamples.removeFirst(_lastSamples.count - 32) }
        }
    }

    /// 仅供测试:复位计数,避免跨用例污染。
    static func reset() { lock.lock(); _total = 0; _lastSamples.removeAll(); lock.unlock() }
}
