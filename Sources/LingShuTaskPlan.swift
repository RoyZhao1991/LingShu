import Foundation

/// 任务执行引擎的核心数据模型：把一个目标拆成「有序、可验收、可观测」的清单。
///
/// 这是替换「模糊并发调度」的新骨架：规划器产出 `LingShuTaskPlan`，单活执行器逐项推进。
/// 同一套清单同时服务普通任务、自主运行(runbook)、会议编排。

enum LingShuPlanItemStatus: String, Codable, Equatable, Sendable {
    case pending = "待执行"
    case running = "执行中"
    case done = "已完成"
    case blocked = "已阻断"
    case skipped = "已跳过"
}

/// 清单里的一个子任务（步骤）。
struct LingShuPlanItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var title: String
    var detail: String
    var status: LingShuPlanItemStatus
    /// 依赖的前置子任务 id；全部 done 才可执行（默认依赖上一项 = 顺序推进）。
    var dependsOn: [String]
    /// 验收门：本步完成前要满足的检查口径（nil = 无显式验收门）。
    var reviewGate: String?
    /// 执行回写的结果摘要。
    var result: String?

    init(
        id: String = "item-\(UUID().uuidString.prefix(8))",
        title: String,
        detail: String = "",
        status: LingShuPlanItemStatus = .pending,
        dependsOn: [String] = [],
        reviewGate: String? = nil,
        result: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.dependsOn = dependsOn
        self.reviewGate = reviewGate
        self.result = result
    }
}

enum LingShuTaskPlanStatus: String, Codable, Equatable, Sendable {
    case queued = "排队中"
    case active = "推进中"
    case completed = "已完成"
    case blocked = "已阻断"
}

/// 一个目标的完整执行计划（= 一条任务）。
struct LingShuTaskPlan: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var objective: String
    /// 话题指纹：用于续接判定（与 LingShuTaskThreadScheduler.fingerprint 同源）。
    var topicFingerprint: String
    var items: [LingShuPlanItem]
    var status: LingShuTaskPlanStatus
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = "plan-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))",
        objective: String,
        topicFingerprint: String,
        items: [LingShuPlanItem],
        status: LingShuTaskPlanStatus = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.objective = objective
        self.topicFingerprint = topicFingerprint
        self.items = items
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 下一个可执行子任务：第一个 pending 且依赖全部 done 的项；无显式依赖时默认要求前一项已完成（顺序）。
    var nextRunnableItem: LingShuPlanItem? {
        for (index, item) in items.enumerated() where item.status == .pending {
            let deps = item.dependsOn.isEmpty
                ? (index > 0 ? [items[index - 1].id] : [])
                : item.dependsOn
            let ready = deps.allSatisfy { depID in
                items.first(where: { $0.id == depID })?.status == .done
            }
            if ready { return item }
        }
        return nil
    }

    var isComplete: Bool {
        !items.isEmpty && items.allSatisfy { $0.status == .done || $0.status == .skipped }
    }

    var isBlocked: Bool {
        items.contains { $0.status == .blocked }
    }

    var doneCount: Int { items.filter { $0.status == .done || $0.status == .skipped }.count }

    var progressLine: String {
        "清单 \(doneCount)/\(items.count) 完成" + (isBlocked ? "（有阻断项）" : "")
    }

    mutating func updateItem(id: String, mutate: (inout LingShuPlanItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
        updatedAt = Date()
    }
}
