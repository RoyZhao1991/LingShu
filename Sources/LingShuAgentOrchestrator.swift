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
    private var sessions: [String: any LingShuAgentSessioning] = [:]
    private var entries: [String: LingShuLedgerEntry] = [:]
    private var order: [String] = []
    /// 正在后台跑的子任务驱动 Task(供"停止并夺回"真正取消跑飞的隔离子任务——它们不计入主状态 hasActiveModelCall,
    /// 旧逻辑根本停不掉,跑飞的 PPT 等夺不回)。终态(record)即清除。
    private var driveTasks: [String: Task<Void, Never>] = [:]
    /// 因网络/网关中断而暂停、等重连自动续跑的子任务 id(会话仍保留在 `sessions`)。
    private var suspendedForReconnect: Set<String> = []
    /// 暂停原因(模型通道网络/超时/限流/服务端异常等)。过去这里统一当"网络",会把 503/限流误报成断网。
    private var suspendedReasons: [String: String] = [:]
    /// 各子任务的目标(续跑时 acceptanceHook 要用,且暂停后 entries 仍保有,这里冗余存一份保险)。
    private var objectives: [String: String] = [:]
    /// 各子任务**随首轮目标直发大脑的图片/PDF**(多模态脑看真图;附件直接入脑覆盖派发任务这条路)。
    private var imageURLsByID: [String: [String]] = [:]
    private(set) var pushes: [String] = []
    /// 事件回灌 UI(MainActor 隔离闭包);由 LingShuState 注入。
    private var onEvent: (@MainActor @Sendable (LingShuOrchestratorEvent) -> Void)?
    /// 子任务**验收 + 恢复**钩子(maker≠checker):(subID, 目标, 子会话, 初始结果) → 驱动到验收通过/恢复后的最终结果。
    /// 由 LingShuState 注入,内部委托主状态统一的 `verifyAndContinue`(撞顶恢复 + 多轮验收 + 测试/运行门 + 停滞交还),
    /// 让子任务与主线程**同一套执行恢复力**,杜绝「主强子弱:复杂工程崩了直接判异常」。
    private var acceptanceHook: (@MainActor @Sendable (String, String, any LingShuAgentSessioning, LingShuAgentRunResult) async -> LingShuAgentRunResult)?

    init(maxConcurrent: Int = 3) {
        concurrency = LingShuConcurrencyManager(maxConcurrent: maxConcurrent)
    }

    func setEventSink(_ sink: @escaping @MainActor @Sendable (LingShuOrchestratorEvent) -> Void) {
        onEvent = sink
    }

    func setAcceptanceHook(_ hook: @escaping @MainActor @Sendable (String, String, any LingShuAgentSessioning, LingShuAgentRunResult) async -> LingShuAgentRunResult) {
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
    func spawn(id: String, objective: String, session: any LingShuAgentSessioning, imageDataURLs: [String]? = nil) async -> LingShuAgentRunResult {
        sessions[id] = session
        let admitted = concurrency.requestAdmission(threadID: id, summary: objective)
        upsert(id: id, objective: objective, status: .running, summary: admitted ? "已开始" : "排队中(超并发上限)")
        await onEvent?(.spawned(id: id, objective: objective))
        let result = await session.send(objective, imageDataURLs: imageDataURLs)
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
    func spawnDetached(id: String, objective: String, session: any LingShuAgentSessioning, imageDataURLs: [String]? = nil) async -> Bool {
        guard concurrency.hasCapacity else { return false }   // 满 3 → 拒绝(背压),不排队
        sessions[id] = session
        objectives[id] = objective
        if let imageDataURLs, !imageDataURLs.isEmpty { imageURLsByID[id] = imageDataURLs }   // 首轮直发大脑的真图
        concurrency.requestAdmission(threadID: id, summary: objective)   // 有容量,必纳入运行
        upsert(id: id, objective: objective, status: .running, summary: "已开始(后台)")
        await onEvent?(.spawned(id: id, objective: objective))
        driveTasks[id] = Task { await self.drive(id: id, objective: objective) }
        return true
    }

    /// 停止**所有正在跑的隔离子任务**(用户"停止并夺回"用)。取消驱动 Task(循环在边界 `Task.isCancelled` 退出)、
    /// 释放并发槽、标记账本,并发 `.failed("用户已停止")` 事件让 UI 把记录从"执行中"收尾。返回停了几条。
    @discardableResult
    func cancelAllRunning() -> Int {
        let ids = Array(driveTasks.keys)
        for (id, task) in driveTasks {
            task.cancel()
            let objective = objectives[id] ?? entries[id]?.objective ?? ""
            upsert(id: id, objective: objective, status: .failed, summary: "用户已停止")
            _ = concurrency.complete(threadID: id)
            Task { await self.onEvent?(.failed(id: id, objective: objective, summary: "用户已停止")) }
        }
        driveTasks.removeAll()
        return ids.count
    }

    /// 停止**指定一条**正在跑的隔离子任务(「进行中」长条的"停止"用):取消其驱动 Task、释放并发槽并放行排队任务、
    /// 标记账本、发 `.failed` 让 UI 收尾。**只动这一条**,不波及其它任务与主会话问答(区别于 cancelAllRunning)。
    /// 返回是否真停了一条(该 id 当前确有在跑的驱动 Task)。
    @discardableResult
    func cancel(id: String) -> Bool {
        guard let task = driveTasks[id] else { return false }
        task.cancel()
        driveTasks[id] = nil
        let objective = objectives[id] ?? entries[id]?.objective ?? ""
        upsert(id: id, objective: objective, status: .failed, summary: "用户已停止")
        Task { await self.onEvent?(.failed(id: id, objective: objective, summary: "用户已停止")) }
        admitNext(after: id)   // 释放槽 + 放行编排器内部排队(状态级队列由 .failed 事件触发晋级)
        return true
    }

    /// 当前后台正在跑的子任务数(供"是否有可停的派发任务"判断)。
    func activeDriveCount() -> Int { driveTasks.count }

    /// 当前仍有活跃 drive 的子任务 id 集合(供"孤儿收割":记录还卡活跃态但编排器已无对应 drive=孤儿)。
    func activeDriveIDs() -> Set<String> { Set(driveTasks.keys) }

    private func drive(id: String, objective: String) async {
        guard let session = sessions[id] else { return }
        var result = await session.send(objective, imageDataURLs: imageURLsByID[id])   // 首轮带真图(多模态脑)
        imageURLsByID[id] = nil   // 图只随首轮发一次,后续续跑不重复带
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

    /// 流程纠正注入到某条隔离子会话(它才是该派发任务真正在跑的 maker)。返回是否注入到一个**正在跑**的循环。
    /// 根治"派发隔离 session 没法 interject 纠偏"——主/自主会话的 interject 够不到编排器里的子会话。
    @discardableResult
    func injectCorrection(id: String, _ text: String) async -> Bool {
        await sessions[id]?.injectCorrection(text) ?? false
    }

    /// 凭账本路由一条后续输入:恰有一个卡住子任务 → 视为在答它;多个 → 返回 nil(交主会话消歧)。
    func routeFollowup(_ text: String) -> String? {
        let blocked = blockedIDs()
        return blocked.count == 1 ? blocked.first : nil
    }

    // MARK: 内部

    private func record(id: String, objective: String, result: LingShuAgentRunResult) {
        driveTasks[id] = nil   // 终态:驱动 Task 已结束,从可取消集合移除
        switch result {
        case .completed(let text):
            upsert(id: id, objective: objective, status: .completed, summary: digest(text))
            pushes.append("子任务「\(objective)」已完成:\(digest(text))")
            Task { await self.onEvent?(.completed(id: id, objective: objective, summary: text)) }
            admitNext(after: id)
        case .blocked(let question):
            let cleanQuestion = LingShuHumanInputEnvelope.userFacingText(from: question)
            upsert(id: id, objective: objective, status: .blocked, summary: "等待你补充", blockedOn: cleanQuestion)
            pushes.append("子任务「\(objective)」卡住,需要你定:\(cleanQuestion)")
            Task { await self.onEvent?(.blocked(id: id, objective: objective, question: question)) }
            // **卡住=等人(无界延迟),不该占用并发槽**——释放槽位 + 放行排队任务(修死锁:多条"等你补充"
            // 占满 3 槽→新任务永远派不出去、系统卡死,看着像"两个子任务处理同一件事死锁")。会话与账本保留,
            // `resumeWithInput` 收到答案后续跑(必要时重新占槽,用户前台续接优先)。
            admitNext(after: id)
        case .maxTurnsReached(let lastText):
            upsert(id: id, objective: objective, status: .failed, summary: "达轮次上限未收尾:\(digest(lastText))")
            pushes.append("子任务「\(objective)」未能自行收尾,已暂停等你介入。")
            Task { await self.onEvent?(.failed(id: id, objective: objective, summary: digest(lastText))) }
            admitNext(after: id)
        case .interrupted(let reason):
            // 模型通道可恢复中断(网络/超时/限流/5xx):**非失败**——标"已暂停"、保留会话上下文、登记待恢复。
            // 恢复后由 resumeInterrupted 重新接上 continueLoop,从中断处续跑。
            upsert(id: id, objective: objective, status: .suspended, summary: LingShuModelServiceFailure.suspendedSummary(for: reason))
            suspendedForReconnect.insert(id)
            suspendedReasons[id] = reason
            pushes.append("子任务「\(objective)」因模型通道暂不可用而暂停,通道恢复后自动续跑。")
            Task { await self.onEvent?(.interrupted(id: id, objective: objective, reason: reason)) }
            admitNext(after: id)
        }
    }

    // MARK: 断网重连续跑 / 手动续接

    /// 当前因模型通道中断而暂停、等恢复续跑的子任务 id 列表。
    func suspendedIDs() -> [String] { order.filter { suspendedForReconnect.contains($0) } }

    /// 当前暂停原因(供 UI/重试循环给出准确状态,避免把限流/503/欠费说成断网)。
    func suspendedReason(id: String) -> String? { suspendedReasons[id] }

    /// 重连后自动续跑一条暂停的子任务:申请并发槽位 → continueLoop()(从中断处接着跑,不注入新消息)→ 验收 → 落账本。
    /// 满并发则**留在暂停集合**稍后再试(不入 waiting 队列,避免被 complete 误用 send 重驱动)。
    func resumeInterrupted(id: String) async {
        guard suspendedForReconnect.contains(id), let session = sessions[id] else { return }
        guard concurrency.hasCapacity || concurrency.isRunning(id) else { return }  // 满 → 留 suspended,下次重连再试
        let objective = objectives[id] ?? entries[id]?.objective ?? ""
        suspendedForReconnect.remove(id)
        suspendedReasons[id] = nil
        concurrency.requestAdmission(threadID: id, summary: objective)
        upsert(id: id, objective: objective, status: .running, summary: "模型通道恢复,自动续跑中")
        await onEvent?(.resumed(id: id, objective: objective))
        driveTasks[id] = Task { await self.driveContinue(id: id, objective: objective, session: session) }
    }

    /// 手动续接(任务窗口/主线程「继续」):把用户输入喂给**这条隔离会话本身**(它才有真上下文)续跑。
    /// 暂停态先消暂停;无论暂停/已完成/卡住,都用 session.resume(把输入接上)再过验收。供 Phase 4 路由。
    @discardableResult
    func resumeWithInput(id: String, input: String) async -> LingShuAgentRunResult? {
        guard let session = sessions[id] else { return nil }
        let objective = objectives[id] ?? entries[id]?.objective ?? ""
        suspendedForReconnect.remove(id)
        suspendedReasons[id] = nil
        if concurrency.hasCapacity, !concurrency.isRunning(id) { concurrency.requestAdmission(threadID: id, summary: objective) }
        upsert(id: id, objective: objective, status: .running, summary: "收到「继续」,续跑中")
        await onEvent?(.resumed(id: id, objective: objective))
        var result = await session.resume(input)
        if let hook = acceptanceHook { result = await hook(id, objective, session, result) }
        record(id: id, objective: objective, result: result)
        return result
    }

    /// 续跑驱动:从中断处 continueLoop()(重发中断那步模型调用),再过统一验收。
    private func driveContinue(id: String, objective: String, session: any LingShuAgentSessioning) async {
        var result = await session.continueLoop()
        if let hook = acceptanceHook { result = await hook(id, objective, session, result) }
        record(id: id, objective: objective, result: result)
    }

    /// 一条线程结束 → 释放 ③ 槽位,有排队的就启动下一条(后台跑)。
    private func admitNext(after id: String) {
        guard let next = concurrency.complete(threadID: id) else { return }
        guard let objective = entries[next]?.objective, sessions[next] != nil else { return }
        upsert(id: next, objective: objective, status: .running, summary: "已开始(后台)")
        driveTasks[next] = Task { await self.drive(id: next, objective: objective) }
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
