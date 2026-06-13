import Foundation

/// 统一的「决策 / 澄清」编排中心。
///
/// 把原本散落、且各自用单槽 optional 互相覆盖的待确认问题（任务续接确认、意图澄清、
/// 操作批准…）收敛成**一个有序队列**：多个问题逐题呈现（多轮弹窗），前一个答完后一个
/// 自动浮现，绝不丢失也绝不互相覆盖。
///
/// 设计取向（按 AGI 标准）：
/// 1. **统一原语**——所有"需要人给一个决策"的场景共用一套排队/定序/推进机制，不再各写一套。
/// 2. **多轮**——`resolveActive` 消解队首后自动呈现下一题；消解过程中新产生的问题排到队尾。
/// 3. **先消解再问**——能从默认/上下文自动定夺的，调用方不必入队（保持"不过度反问"）。
/// 4. **非交互兜底**——自主 / 无头 / 定时场景下 `isNonInteractive` 为真时新问题直接走
///    `autoResolve` 安全默认，不阻塞无人值守执行（正是任务续接死锁那一类的根治）。
/// 5. **可插拔**——真正的"呈现"和"消解"逻辑由调用方以闭包注入，本中心不绑定任何具体问题类型。
@MainActor
final class LingShuClarificationCenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        /// 审计 / 策略用的类别名（"任务续接" / "意图澄清" / "操作批准"…）。
        let kind: String
        let taskRecordID: String?
        /// 把这道题呈现给用户（落选择卡 / 抛澄清问题）。仅在它成为队首时调用一次。
        let present: () -> Void
        /// 非交互场景（自主 / 无头 / 定时）的默认定夺：不弹卡、按安全默认直接推进。
        let autoResolve: () -> Void
    }

    @Published private(set) var queue: [Request] = []
    private var presentedID: UUID?

    var activeRequest: Request? { queue.first }
    var hasPending: Bool { !queue.isEmpty }
    var pendingCount: Int { queue.count }

    /// 非交互判定（由 State 注入：自主运行中且非观察模式 / 无头驱动 / 定时触发等）。
    /// 返回 true 时新问题直接 `autoResolve`，不入队、不打扰用户。
    var isNonInteractive: () -> Bool = { false }

    /// 提交一道待确认问题：队列空则立即呈现；否则排队，等前序消解后逐题浮现。
    func submit(_ request: Request) {
        if isNonInteractive() {
            request.autoResolve()
            return
        }
        queue.append(request)
        presentHeadIfNeeded()
    }

    /// 便捷构造并提交。
    @discardableResult
    func submit(
        kind: String,
        taskRecordID: String?,
        present: @escaping () -> Void,
        autoResolve: @escaping () -> Void
    ) -> Bool {
        let request = Request(kind: kind, taskRecordID: taskRecordID, present: present, autoResolve: autoResolve)
        if isNonInteractive() {
            request.autoResolve()
            return false   // 未入队（已自动定夺）
        }
        queue.append(request)
        presentHeadIfNeeded()
        return true
    }

    /// 当前问题已消解（用户点选 / 文字答复，或系统裁决）：出队队首，执行消解动作，
    /// 再呈现下一题（多轮）。消解过程中若再产生新问题，会自然排到队尾、稍后浮现。
    func resolveActive(_ resolve: () -> Void) {
        guard !queue.isEmpty else { resolve(); return }
        presentedID = nil
        queue.removeFirst()
        resolve()
        presentHeadIfNeeded()
    }

    /// 当前问题已在外部消解完毕（调用方自己跑完了续接 / 澄清逻辑）：仅出队并呈现下一题，
    /// 不再执行消解闭包。用于那些消解逻辑天然内联、又要推进多轮队列的路径。
    func advanceAfterExternalResolution() {
        guard !queue.isEmpty else { return }
        presentedID = nil
        queue.removeFirst()
        presentHeadIfNeeded()
    }

    /// 丢弃全部待确认（例如用户切换话题 / 主动取消）。
    func cancelAll() {
        queue.removeAll()
        presentedID = nil
    }

    /// 队首尚未呈现就呈现它——幂等，避免消解时的重入造成重复弹卡。
    private func presentHeadIfNeeded() {
        guard let head = queue.first, presentedID != head.id else { return }
        presentedID = head.id
        head.present()
    }
}
