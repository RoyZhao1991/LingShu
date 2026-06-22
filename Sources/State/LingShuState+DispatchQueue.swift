import Foundation

/// **派发队列区**(用户定调 2026-06-22):主界面 task 支持 3 并发(= 编排器 maxConcurrent),
/// 多出来的**不直接派发**,进一个**可见的队列区等待**;有空位时自动晋级派发;晋级前用户可在队列区**删除**。
/// 与编排器内部并发队列分工:这条是**派发前**的用户可见可删队列(承载已分诊为 task、但当前并发已满的请求)。
/// 自主模式单线程推进不受影响(它不走这条 task 派发路径)。
struct LingShuQueuedDispatchTask: Identifiable, Equatable {
    let id: String
    let prompt: String
    let goal: String?
    /// 入队前已派生的前置认知(GoalSpec/缺口/能力需求)——晋级派发时直接绑定,免重复模型调用。
    let goalSpec: LingShuGoalSpec?
    let gap: LingShuGapAnalysis?
    let requirements: [LingShuCapabilityRequirement]
    let createdAt: Date

    init(prompt: String, goal: String?, goalSpec: LingShuGoalSpec?, gap: LingShuGapAnalysis?,
         requirements: [LingShuCapabilityRequirement], createdAt: Date = Date()) {
        self.id = "queued-\(UUID().uuidString.prefix(8))"
        self.prompt = prompt
        self.goal = goal
        self.goalSpec = goalSpec
        self.gap = gap
        self.requirements = requirements
        self.createdAt = createdAt
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
    func enqueueDispatchTask(prompt: String, goal: String?, goalSpec: LingShuGoalSpec?,
                            gap: LingShuGapAnalysis?, requirements: [LingShuCapabilityRequirement]) {
        let item = LingShuQueuedDispatchTask(prompt: prompt, goal: goal, goalSpec: goalSpec, gap: gap, requirements: requirements)
        queuedDispatchTasks.append(item)
        appendTrace(kind: .route, actor: "派发队列", title: "进队列区等待",
                    detail: "并发已满,本条进队列区等空位;晋级前可删除。")
        // 加载气泡里也提示一句(队列区在 UI 单独呈现;这里不创建任务记录,避免提前进主窗口)。
        chatMessages.append(.init(speaker: "灵枢", text: "📥 已加入队列区等待(前面满 3 并发);有空位我自动开始,排期间你可在队列区删掉它。", isUser: false))
    }

    /// 用户在队列区删除一条**尚未派发**的排队任务。
    func removeQueuedDispatchTask(id: String) {
        guard let idx = queuedDispatchTasks.firstIndex(where: { $0.id == id }) else { return }
        let removed = queuedDispatchTasks.remove(at: idx)
        appendTrace(kind: .route, actor: "派发队列", title: "已从队列区删除", detail: String(removed.prompt.prefix(36)))
    }

    /// 有空位 → 把队列区最早的一条晋级为真派发(创建记录 + 绑定前置认知 + dispatchIsolatedTask)。
    /// 在任务收尾/卡住释放槽位后调用;可能连续晋级多条直到填满或队列空。
    func promoteQueuedDispatchIfPossible() {
        guard !queuedDispatchTasks.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let running = await self.agentOrchestrator.runningCount()
            let cap = await self.agentOrchestrator.capacity()
            guard !Self.shouldQueueDispatch(running: running, capacity: cap), !self.queuedDispatchTasks.isEmpty else { return }
            let next = self.queuedDispatchTasks.removeFirst()
            let rid = self.createTaskExecutionRecord(for: next.prompt)
            self.bindGoalSpec(next.goalSpec, to: rid)
            self.bindGapAnalysis(next.gap, to: rid)
            self.bindCapabilityRequirements(next.requirements, to: rid)
            self.appendTrace(kind: .route, actor: "派发队列", title: "晋级派发", detail: "有空位,队列区最早一条开始执行:\(String(next.prompt.prefix(28)))")
            self.dispatchIsolatedTask(prompt: next.prompt, taskRecordID: rid, goal: next.goal)
            // 可能还有空位 + 更多排队 → 继续晋级下一条。
            self.promoteQueuedDispatchIfPossible()
        }
    }
}
