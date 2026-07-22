import Foundation

/// **派发队列区**(用户定调 2026-06-22;并发改 1 串行 2026-06-23):主界面 task **串行**(编排器 maxConcurrent=1),
/// 同时只允许一条在执行;多出来的**不直接派发**,进一个**可见的队列区等待**;前一条完成后自动晋级派发;晋级前用户可在队列区**删除**。
/// 与编排器内部并发队列分工:这条是**派发前**的用户可见可删队列(承载已分诊为 task、但当前并发已满的请求)。
/// 自主模式单线程推进不受影响(它不走这条 task 派发路径)。
struct LingShuQueuedDispatchTask: Identifiable, Equatable {
    let id: String
    let prompt: String
    let visiblePrompt: String
    let goal: String?
    /// 入队前已派生的前置认知(GoalSpec/缺口/能力需求)——晋级派发时直接绑定,免重复模型调用。
    let goalSpec: LingShuGoalSpec?
    let gap: LingShuGapAnalysis?
    let requirements: [LingShuCapabilityRequirement]
    let createdAt: Date
    /// 主对话里紧跟用户消息的答复气泡。任务排队时复用它显示"已入队",晋级时继续复用它显示执行进度,
    /// 保证聊天流永远是一问一答,不把多条用户消息堆在一起。
    let bubbleID: UUID?
    /// 入队时暂存的**直发大脑的图片/PDF**(排队后 pendingDirectBrainImages 会被清/覆盖,故随队列项带住,晋级时直发)。
    let imageDataURLs: [String]?

    init(prompt: String, visiblePrompt: String? = nil, goal: String?, goalSpec: LingShuGoalSpec?, gap: LingShuGapAnalysis?,
         requirements: [LingShuCapabilityRequirement], createdAt: Date = Date(), bubbleID: UUID? = nil,
         imageDataURLs: [String]? = nil) {
        self.id = "queued-\(UUID().uuidString.prefix(8))"
        self.prompt = prompt
        self.visiblePrompt = (visiblePrompt ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        self.goal = goal
        self.goalSpec = goalSpec
        self.gap = gap
        self.requirements = requirements
        self.createdAt = createdAt
        self.bubbleID = bubbleID
        self.imageDataURLs = imageDataURLs
    }

    static func == (a: LingShuQueuedDispatchTask, b: LingShuQueuedDispatchTask) -> Bool { a.id == b.id }
}

@MainActor
extension LingShuState {

    /// 派发前的并发判定(纯逻辑,可单测):当前真并行数 ≥ 上限 → 该进队列区(不直接派发)。
    nonisolated static func shouldQueueDispatch(running: Int, capacity: Int) -> Bool {
        running >= max(1, capacity)
    }

    /// 并发已满 → 把这条(已分诊为 task)请求放进**可见队列区等待**,不创建记录/不派发。带上已派生的前置认知,晋级时直接用。
    func enqueueDispatchTask(prompt: String, visiblePrompt: String? = nil, goal: String?, goalSpec: LingShuGoalSpec?,
                            gap: LingShuGapAnalysis?, requirements: [LingShuCapabilityRequirement],
                            existingBubbleID: UUID? = nil) {
        // 入队时把"直发大脑的图"消费下来随队列项带住(晋级派发时 pending 早已被清/覆盖)。
        let item = LingShuQueuedDispatchTask(prompt: prompt, visiblePrompt: visiblePrompt, goal: goal, goalSpec: goalSpec, gap: gap,
                                             requirements: requirements, bubbleID: existingBubbleID,
                                             imageDataURLs: consumePendingDirectBrainImages())
        queuedDispatchTasks.append(item)
        appendTrace(kind: .route, actor: "派发队列", title: "进队列区等待",
                    detail: "并发已满,本条进队列区等空位;晋级前可删除。")
        // 复用 submitTextInput 已经紧跟用户消息创建的占位气泡,不要删掉再尾部追加,
        // 否则快速连发会变成"多个问题在上、多个回答在下"。
        let text = "📥 已加入队列区等待(前面有任务在执行);前一条完成后我自动开始,排期间你可在队列区删掉它。"
        if let existingBubbleID, let idx = chatMessages.firstIndex(where: { $0.id == existingBubbleID }) {
            chatMessages[idx].text = text
            chatMessages[idx].isLoading = false
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: text, isUser: false))
        }
    }

    /// 当前正在执行的子线程——供「进行中」长条自动定位。
    /// 运行态来自独立的子线程活动投影，不再依赖主对话是否恰好存在加载气泡。
    var runningDispatchedTask: LingShuTaskExecutionRecord? {
        taskExecutionRecordLookup
            .filter { activeTaskThreadRecordIDs.contains($0.id) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// 清掉不再占执行槽的派发气泡映射。旧版本/异常路径可能把 `waitingForUser`、`partial`、
    /// `failed` 等非活跃记录残留在 dispatchedTaskBubbles, 导致后续任务一直误判"前面有任务在执行"。
    func pruneInactiveDispatchedTaskBubbles() {
        let active: Set<LingShuTaskExecutionStatus> = [.running, .dispatched, .analyzing, .acquiringCapability, .ready]
        let statusByID = Dictionary(uniqueKeysWithValues: taskExecutionRecords.map { ($0.id, $0.status) })
        let staleIDs = dispatchedTaskBubbles.keys.filter { recordID in
            guard let status = statusByID[recordID] else { return true }
            return !active.contains(status)
        }
        guard !staleIDs.isEmpty else { return }
        for id in staleIDs { dispatchedTaskBubbles.removeValue(forKey: id) }
        appendTrace(kind: .system, actor: "派发队列", title: "释放非活跃槽位", detail: "清理 \(staleIDs.count) 条已停止/待用户/终态任务的活跃映射。")
    }

    /// 停止指定派发任务(「进行中」长条的"停止"):recordID → subID → 编排器只取消这一条,
    /// 释放槽位让队列自动晋级;**不动问答线**(区别于 cancelCurrentCall 的全停)。
    func stopDispatchedTask(recordID: String) {
        if stopSharedKernelTaskIfNeeded(recordID: recordID) { return }
        guard let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key else {
            markTaskRecordManuallyStopped(recordID)
            dispatchedTaskBubbles.removeValue(forKey: recordID)
            if blockedDispatchedRecordID == recordID { blockedDispatchedRecordID = nil }
            appendTaskRecordMessage(recordID, actor: "用户", role: "停止", kind: .warning, text: "用户已停止该任务。")
            finishTaskRecord(recordID, status: .failed, summary: "用户已停止该任务。")
            manuallyStoppedTaskRecords.remove(recordID)
            promoteQueuedDispatchIfPossible()
            return
        }
        appendTrace(kind: .warning, actor: "用户", title: "停止任务", detail: "进行中长条手动停止该派发任务,释放槽位。")
        markTaskRecordManuallyStopped(recordID)
        let orchestrator = agentOrchestrator
        Task { @MainActor [weak self] in
            let stopped = await orchestrator.cancel(id: subID)
            guard !stopped, let self else { return }
            // 编排器没有活跃 driveTask,但 UI 记录仍处于执行/待用户等非终态时,本地兜底收口。
            self.dispatchedTaskBubbles.removeValue(forKey: recordID)
            if self.blockedDispatchedRecordID == recordID { self.blockedDispatchedRecordID = nil }
            self.markTaskRecordManuallyStopped(recordID)
            self.appendTaskRecordMessage(recordID, actor: "用户", role: "停止", kind: .warning, text: "用户已停止该任务。")
            self.finishTaskRecord(recordID, status: .failed, summary: "用户已停止该任务。")
            self.manuallyStoppedTaskRecords.remove(recordID)
            self.promoteQueuedDispatchIfPossible()
        }
    }

    /// **派发任务孤儿收割(2026-06-27 根治僵死执行中堵死队列)**:记录还卡在活跃态(.running/.dispatched/…),
    /// 但编排器已无对应 drive(驱动早结束/异常退出却没置终态)→ 自动收口成 .partial、移除气泡、释放串行队列。
    /// 根因:currentlyExecutingTurn 把卡 .running 的派发气泡当"执行中"、prune 又只清终态 → 队列永久死锁。
    func reapOrphanedDispatchedTasks() async {
        let trackedRecordIDs = activeTaskThreadRecordIDs.union(dispatchedTaskBubbles.keys)
        guard !trackedRecordIDs.isEmpty else { return }
        let liveIDs = await agentOrchestrator.activeDriveIDs()
        let active: Set<LingShuTaskExecutionStatus> = [.running, .dispatched, .analyzing, .acquiringCapability, .ready]
        var reaped = false
        for recordID in trackedRecordIDs {
            guard let status = taskExecutionRecords.first(where: { $0.id == recordID })?.status,
                  active.contains(status) else { continue }
            if livePipelineRecordIDs.contains(recordID) { continue }   // **角色管线正在驱动它**(直接 Task,不在 orchestrator drive 里)→ 不是孤儿,跳过
            let subID = agentSubTaskRecords.first(where: { $0.value == recordID })?.key
            if let subID, liveIDs.contains(subID) { continue }   // 真有活跃 drive → 不是孤儿,跳过
            // **角色管线孤儿 → 复用产物自动续跑**(用户定调 2026-06-28),别收口成 .partial 摆死。
            if let rec = taskExecutionRecords.first(where: { $0.id == recordID }),
               isRolePipelineRecord(rec), !rolePipelineAgents(for: rec).isEmpty {
                dispatchedTaskBubbles.removeValue(forKey: recordID)
                Task { @MainActor [weak self] in await self?.resumeOrphanedRolePipeline(rec) }   // 别 await(续跑是分钟级,看门狗不能被堵)
                reaped = true
                continue
            }
            dispatchedTaskBubbles.removeValue(forKey: recordID)
            if blockedDispatchedRecordID == recordID { blockedDispatchedRecordID = nil }
            appendTaskRecordMessage(recordID, actor: "系统", role: "自动收口", kind: .warning,
                                    text: "检测到任务驱动已结束但状态未收口(孤儿),自动置为部分完成、释放队列。")
            finishTaskRecord(recordID, status: .partial, summary: "驱动意外结束、状态未收口,看门狗自动收口。")
            reaped = true
        }
        if reaped { promoteQueuedDispatchIfPossible(); drainSerialInputsIfIdle() }
    }

    /// 停止所有活跃派发任务(供 lingshu_stop / 全局停止——原 lingshu_stop 只取消主线程调用、停不掉派发任务)。返回停了几条。
    @discardableResult
    func stopAllDispatchedTasks() -> Int {
        let ids = Array(activeTaskThreadRecordIDs.union(dispatchedTaskBubbles.keys))
        for id in ids { stopDispatchedTask(recordID: id) }
        return ids.count
    }

    /// 启动派发看门狗:每 20s 收割一次孤儿任务(防僵死执行中永久堵塞串行队列)。幂等。
    func startDispatchWatchdogIfNeeded() {
        guard dispatchWatchdogTimer == nil else { return }
        dispatchWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reapOrphanedDispatchedTasks() }
        }
    }

    /// 用户在队列区删除一条**尚未派发**的排队任务。
    func removeQueuedDispatchTask(id: String) {
        guard let idx = queuedDispatchTasks.firstIndex(where: { $0.id == id }) else { return }
        let removed = queuedDispatchTasks.remove(at: idx)
        appendTrace(kind: .route, actor: "派发队列", title: "已从队列区删除", detail: String(removed.prompt.prefix(36)))
        if let bubbleID = removed.bubbleID, let idx = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[idx].text = "已从队列区移除。"
            chatMessages[idx].isLoading = false
        }
    }

    /// 有空位 → 把队列区最早的一条晋级为真派发(创建记录 + 绑定前置认知 + dispatchIsolatedTask)。
    /// 在任务收尾/卡住释放槽位后调用;可能连续晋级多条直到填满或队列空。
    func promoteQueuedDispatchIfPossible() {
        // 单串行(2026-06-25):任务子线程释放槽位 → 若已空闲,出队串行输入队列的下一条。
        // 放在最前:即便没有 queuedDispatchTasks 待晋级,也要 drain 串行队列(它承载所有新输入)。
        drainSerialInputsIfIdle()
        guard !queuedDispatchTasks.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cap = await self.agentOrchestrator.capacity()
            self.pruneInactiveDispatchedTaskBubbles()
            // **竞态修(2026-06-23,监工"两条任务同时在跑/TASK_NONSERIAL"):**晋级容量判定改用**同步活跃派发气泡数**
            // (dispatchIsolatedTask 同步置 dispatchedTaskBubbles),而非 `await runningCount()`。原 await 是交错点:
            // 每个编排器事件都触发一次 promote,两个并发 promote 都在 dispatch 前读到 running=0 → 双双 removeFirst+派发 →
            // 同时两条在跑(违反串行)。改后:capacity 的 await 之后到派发之间**无 await**,MainActor 串行执行使
            // 每个 promote 的"读计数→派发(计数+1)"原子完成,第二个 promote 读到已满 → 不再双派发。
            guard self.activeTaskThreadRecordIDs.count < max(1, cap), !self.queuedDispatchTasks.isEmpty else { return }
            let next = self.queuedDispatchTasks.removeFirst()
            let rid = self.createTaskExecutionRecord(for: next.visiblePrompt)
            self.bindGoalSpec(next.goalSpec, to: rid)
            self.bindGapAnalysis(next.gap, to: rid)
            self.bindCapabilityRequirements(next.requirements, to: rid)
            self.appendTrace(kind: .route, actor: "派发队列", title: "晋级派发", detail: "有空位,队列区最早一条开始执行:\(String(next.visiblePrompt.prefix(28)))")
            self.dispatchIsolatedTask(prompt: next.prompt, taskRecordID: rid, goal: next.goal, existingBubbleID: next.bubbleID, imageDataURLs: next.imageDataURLs)
            // 可能还有空位 + 更多排队 → 继续晋级下一条。
            self.promoteQueuedDispatchIfPossible()
        }
    }
}
