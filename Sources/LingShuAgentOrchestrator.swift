import Foundation

/// 统一账本条目:子任务/未决项的薄摘要(不含完整上下文)。
/// 一条卡住的子会话 = 一条未决回路;回指消解、子线程汇报、续接路由共用这一份账本。
enum LingShuLedgerStatus: String, Equatable, Sendable {
    case running = "推进中"
    case blocked = "已卡住"
    case completed = "已完成"
    case failed = "已失败"
    /// 基础设施中断(网络/网关)导致暂停——**非失败**,保留会话上下文,重连后自动续跑。
    case suspended = "已暂停"
}

struct LingShuLedgerEntry: Identifiable, Equatable, Sendable {
    let id: String
    var objective: String
    var status: LingShuLedgerStatus
    var summary: String
    /// 卡住时:在等用户定的那个点。
    var blockedOn: String?
    var updatedAt: Date
}

/// 编排器对外事件:桥接到 UI(创建任务记录、把结果/推送回灌对话)。
enum LingShuOrchestratorEvent: Sendable {
    case spawned(id: String, objective: String)
    case completed(id: String, objective: String, summary: String)
    case blocked(id: String, objective: String, question: String)
    case failed(id: String, objective: String, summary: String)
    /// 网络/网关中断导致暂停(非失败):上下文保留,重连后自动续跑。
    case interrupted(id: String, objective: String, reason: String)
    /// 重连后自动续跑开始(供 UI 把任务从"已暂停"翻回"执行中")。
    case resumed(id: String, objective: String)
}

/// Agent 编排器(范式骨干的整合层)。
///
/// 主会话派生隔离子会话(各跑各的 `LingShuAgentSession`,由 ③ 有界并发统计),
/// 子会话在 完成/卡住/失败 时把【摘要事件】回报到统一账本 → 主动推送给用户;
/// 用户后续输入凭账本路由回正确的子会话续跑。
/// 隔离的是「完整上下文」,共享的是「账本薄摘要」——既真并行又不路由模糊。
actor LingShuAgentOrchestrator {
    private var concurrency: LingShuConcurrencyManager
    private var sessions: [String: LingShuAgentSession] = [:]
    private var entries: [String: LingShuLedgerEntry] = [:]
    private var order: [String] = []
    /// 因网络/网关中断而暂停、等重连自动续跑的子任务 id(会话仍保留在 `sessions`)。
    private var suspendedForReconnect: Set<String> = []
    /// 各子任务的目标(续跑时 acceptanceHook 要用,且暂停后 entries 仍保有,这里冗余存一份保险)。
    private var objectives: [String: String] = [:]
    private(set) var pushes: [String] = []
    /// 事件回灌 UI(MainActor 隔离闭包);由 LingShuState 注入。
    private var onEvent: (@MainActor @Sendable (LingShuOrchestratorEvent) -> Void)?
    /// 子任务**验收 + 恢复**钩子(maker≠checker):(subID, 目标, 子会话, 初始结果) → 驱动到验收通过/恢复后的最终结果。
    /// 由 LingShuState 注入,内部委托主状态统一的 `verifyAndContinue`(撞顶恢复 + 多轮验收 + 测试/运行门 + 停滞交还),
    /// 让子任务与主线程**同一套执行恢复力**,杜绝「主强子弱:复杂工程崩了直接判异常」。
    private var acceptanceHook: (@MainActor @Sendable (String, String, LingShuAgentSession, LingShuAgentRunResult) async -> LingShuAgentRunResult)?

    init(maxConcurrent: Int = 3) {
        concurrency = LingShuConcurrencyManager(maxConcurrent: maxConcurrent)
    }

    func setEventSink(_ sink: @escaping @MainActor @Sendable (LingShuOrchestratorEvent) -> Void) {
        onEvent = sink
    }

    func setAcceptanceHook(_ hook: @escaping @MainActor @Sendable (String, String, LingShuAgentSession, LingShuAgentRunResult) async -> LingShuAgentRunResult) {
        acceptanceHook = hook
    }

    // MARK: 快照(可观测 / 主会话路由用)

    func ledger() -> [LingShuLedgerEntry] { order.compactMap { entries[$0] } }
    func pendingPushes() -> [String] { pushes }
    func runningCount() -> Int { concurrency.runningCount }
    func waitingCount() -> Int { concurrency.waitingCount }
    /// 同时可并行运行的子任务硬上限(= 有界并发 maxConcurrent)。spawn_task 据此做背压。
    func capacity() -> Int { concurrency.maxConcurrent }
    /// 当前是否还能再派生一条子任务(运行数 < 上限)。
    func hasSpawnCapacity() -> Bool { concurrency.hasCapacity }
    func blockedIDs() -> [String] { ledger().filter { $0.status == .blocked }.map { $0.id } }

    // MARK: 派生 / 续接

    /// 派生一条隔离子会话并跑到第一个停止点(完成/卡住/失败),把摘要事件落账本 + 推送。
    /// 真并行 = 并发调用本方法(每条子会话是独立 actor)。
    @discardableResult
    func spawn(id: String, objective: String, session: LingShuAgentSession) async -> LingShuAgentRunResult {
        sessions[id] = session
        let admitted = concurrency.requestAdmission(threadID: id, summary: objective)
        upsert(id: id, objective: objective, status: .running, summary: admitted ? "已开始" : "排队中(超并发上限)")
        await onEvent?(.spawned(id: id, objective: objective))
        let result = await session.send(objective)
        record(id: id, objective: objective, result: result)
        return result
    }

    /// 非阻塞派生:子会话在后台跑(真并行),立即返回;完成/失败后自动纳入下一条排队线程。
    /// 主会话用它"派生即走",子会话经账本/推送回报,不阻塞主会话。
    ///
    /// **硬上限(背压):已有 `maxConcurrent`(=3)条在跑时直接拒绝,不入队**——返回 false,由
    /// spawn_task 把"已满,稍后再派/本会话顺序做"如实回报给模型。这样杜绝无界排队堆积(模型一次
    /// 甩出几十个子任务排队空耗),把"最多 3 条正在运行"做成派生点的硬闸,而非仅靠内部队列兜。
    @discardableResult
    func spawnDetached(id: String, objective: String, session: LingShuAgentSession) async -> Bool {
        guard concurrency.hasCapacity else { return false }   // 满 3 → 拒绝(背压),不排队
        sessions[id] = session
        objectives[id] = objective
        concurrency.requestAdmission(threadID: id, summary: objective)   // 有容量,必纳入运行
        upsert(id: id, objective: objective, status: .running, summary: "已开始(后台)")
        await onEvent?(.spawned(id: id, objective: objective))
        Task { await self.drive(id: id, objective: objective) }
        return true
    }

    private func drive(id: String, objective: String) async {
        guard let session = sessions[id] else { return }
        var result = await session.send(objective)
        // 子任务**验收 + 恢复**:委托主状态统一的 verifyAndContinue(与主会话/自主运行同一套——撞顶当检查点续跑恢复、
        // 多轮验收、测试/运行门、停滞才诚实交还)。不再在编排器里跑弱化的 3 轮验收 + 撞顶直接判失败。
        if let hook = acceptanceHook {
            result = await hook(id, objective, session, result)
        }
        record(id: id, objective: objective, result: result)
    }

    /// 续接:把用户补充的答案路由给某条卡住的子会话,续跑。
    @discardableResult
    func resume(id: String, answer: String) async -> LingShuAgentRunResult? {
        guard let session = sessions[id], entries[id]?.status == .blocked else { return nil }
        let objective = entries[id]?.objective ?? ""
        upsert(id: id, objective: objective, status: .running, summary: "已收到补充,续跑中")
        let result = await session.resume(answer)
        record(id: id, objective: objective, result: result)
        return result
    }

    /// 凭账本路由一条后续输入:恰有一个卡住子任务 → 视为在答它;多个 → 返回 nil(交主会话消歧)。
    func routeFollowup(_ text: String) -> String? {
        let blocked = blockedIDs()
        return blocked.count == 1 ? blocked.first : nil
    }

    // MARK: 内部

    private func record(id: String, objective: String, result: LingShuAgentRunResult) {
        switch result {
        case .completed(let text):
            upsert(id: id, objective: objective, status: .completed, summary: digest(text))
            pushes.append("子任务「\(objective)」已完成:\(digest(text))")
            Task { await self.onEvent?(.completed(id: id, objective: objective, summary: text)) }
            admitNext(after: id)
        case .blocked(let question):
            upsert(id: id, objective: objective, status: .blocked, summary: "等待你补充", blockedOn: question)
            pushes.append("子任务「\(objective)」卡住,需要你定:\(question)")
            Task { await self.onEvent?(.blocked(id: id, objective: objective, question: question)) }
            // 卡住保留 ③ 槽位(暂停而非结束);收到答案 resume 后续跑。
        case .maxTurnsReached(let lastText):
            upsert(id: id, objective: objective, status: .failed, summary: "达轮次上限未收尾:\(digest(lastText))")
            pushes.append("子任务「\(objective)」未能自行收尾,已暂停等你介入。")
            Task { await self.onEvent?(.failed(id: id, objective: objective, summary: digest(lastText))) }
            admitNext(after: id)
        case .interrupted(let reason):
            // 网络/网关中断:**非失败**——标"已暂停"、保留会话上下文、登记待重连,释放并发槽位(断网时本就没法跑别的)。
            // 重连后由 resumeInterrupted 重新接上 continueLoop,从中断处续跑。
            upsert(id: id, objective: objective, status: .suspended, summary: "网络中断已暂停:\(digest(reason))")
            suspendedForReconnect.insert(id)
            pushes.append("子任务「\(objective)」因网络中断暂停,联网后自动续跑。")
            Task { await self.onEvent?(.interrupted(id: id, objective: objective, reason: reason)) }
            admitNext(after: id)
        }
    }

    // MARK: 断网重连续跑 / 手动续接

    /// 当前因网络中断而暂停、等重连续跑的子任务 id 列表。
    func suspendedIDs() -> [String] { order.filter { suspendedForReconnect.contains($0) } }

    /// 重连后自动续跑一条暂停的子任务:申请并发槽位 → continueLoop()(从中断处接着跑,不注入新消息)→ 验收 → 落账本。
    /// 满并发则**留在暂停集合**稍后再试(不入 waiting 队列,避免被 complete 误用 send 重驱动)。
    func resumeInterrupted(id: String) async {
        guard suspendedForReconnect.contains(id), let session = sessions[id] else { return }
        guard concurrency.hasCapacity || concurrency.isRunning(id) else { return }  // 满 → 留 suspended,下次重连再试
        let objective = objectives[id] ?? entries[id]?.objective ?? ""
        suspendedForReconnect.remove(id)
        concurrency.requestAdmission(threadID: id, summary: objective)
        upsert(id: id, objective: objective, status: .running, summary: "网络恢复,自动续跑中")
        await onEvent?(.resumed(id: id, objective: objective))
        Task { await self.driveContinue(id: id, objective: objective, session: session) }
    }

    /// 手动续接(任务窗口/主线程「继续」):把用户输入喂给**这条隔离会话本身**(它才有真上下文)续跑。
    /// 暂停态先消暂停;无论暂停/已完成/卡住,都用 session.resume(把输入接上)再过验收。供 Phase 4 路由。
    @discardableResult
    func resumeWithInput(id: String, input: String) async -> LingShuAgentRunResult? {
        guard let session = sessions[id] else { return nil }
        let objective = objectives[id] ?? entries[id]?.objective ?? ""
        suspendedForReconnect.remove(id)
        if concurrency.hasCapacity, !concurrency.isRunning(id) { concurrency.requestAdmission(threadID: id, summary: objective) }
        upsert(id: id, objective: objective, status: .running, summary: "收到「继续」,续跑中")
        await onEvent?(.resumed(id: id, objective: objective))
        var result = await session.resume(input)
        if let hook = acceptanceHook { result = await hook(id, objective, session, result) }
        record(id: id, objective: objective, result: result)
        return result
    }

    /// 续跑驱动:从中断处 continueLoop()(重发中断那步模型调用),再过统一验收。
    private func driveContinue(id: String, objective: String, session: LingShuAgentSession) async {
        var result = await session.continueLoop()
        if let hook = acceptanceHook { result = await hook(id, objective, session, result) }
        record(id: id, objective: objective, result: result)
    }

    /// 一条线程结束 → 释放 ③ 槽位,有排队的就启动下一条(后台跑)。
    private func admitNext(after id: String) {
        guard let next = concurrency.complete(threadID: id) else { return }
        guard let objective = entries[next]?.objective, sessions[next] != nil else { return }
        upsert(id: next, objective: objective, status: .running, summary: "已开始(后台)")
        Task { await self.drive(id: next, objective: objective) }
    }

    private func upsert(id: String, objective: String, status: LingShuLedgerStatus, summary: String, blockedOn: String? = nil) {
        if entries[id] == nil { order.append(id) }
        entries[id] = .init(id: id, objective: objective, status: status, summary: summary, blockedOn: blockedOn, updatedAt: Date())
    }

    private func digest(_ text: String, limit: Int = 60) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }
}
