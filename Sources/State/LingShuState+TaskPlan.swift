import Foundation

/// 先计划后执行(LOOP 标准流程)——`update_plan` 工具让模型落地多步任务时先列计划清单、再逐步执行并更新状态。
/// 计划存在任务记录的 `plan` 字段(在任务窗口顶部渲染成 todo)。简单问答/纯对话不需要 plan。
@MainActor
extension LingShuState {

    /// update_plan 工具:模型据此列出/更新本任务执行计划(每步 title + status)。
    func updateTaskPlanTool(recordIDProvider: @escaping @MainActor @Sendable () -> String?) -> LingShuAgentTool {
        LingShuAgentTool(
            name: "update_plan",
            description: "列出/更新本任务的执行计划清单(LOOP 标准:先 plan 再逐步执行)。开始任何多步任务**先调用**列出 3–7 步;之后每推进一步再调用更新对应 step 的 status(pending/in_progress/completed)。简单一问一答/纯对话不需要。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"steps\":{\"type\":\"array\",\"description\":\"计划步骤,每项 {title, status}\",\"items\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"status\":{\"type\":\"string\",\"description\":\"pending / in_progress / completed\"}}}}},\"required\":[\"steps\"]}"
        ) { [weak self] argsJSON in
            let steps = Self.parsePlanSteps(argsJSON)
            guard !steps.isEmpty else { return "计划为空——请给出至少一步 {title}。" }
            await MainActor.run { [weak self] in self?.applyTaskPlan(steps, recordID: recordIDProvider()) }
            let body = steps.enumerated().map { "\($0.offset + 1). [\($0.element.status.rawValue)] \($0.element.title)" }.joined(separator: "\n")
            return "已更新执行计划(\(steps.count) 步):\n\(body)\n按计划逐步执行,每完成一步再 update_plan 标记状态。"
        }
    }

    /// 把计划写进当前任务记录并持久化(窗口顶部据此渲染 todo)。
    func applyTaskPlan(_ steps: [LingShuPlanStep], recordID: String?) {
        guard let recordID, let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[index].plan = steps
        taskExecutionRecords[index].updatedAt = Date()
        persistTaskExecutionRecords()
    }

    /// 解析 update_plan 参数为计划步骤(纯函数,可测)。
    nonisolated static func parsePlanSteps(_ json: String) -> [LingShuPlanStep] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["steps"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let raw = (item["status"] as? String ?? "pending").lowercased()
            let status: LingShuPlanStep.Status
            if raw.contains("progress") || raw.contains("进行") || raw.contains("doing") {
                status = .inProgress
            } else if raw.contains("complete") || raw.contains("done") || raw.contains("完成") || raw.contains("finish") {
                status = .completed
            } else {
                status = .pending
            }
            return LingShuPlanStep(title: title, status: status)
        }
    }

    /// 人类可读的总用时(供回复末尾"总用时"展示)。
    nonisolated static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)秒" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes)分" : "\(minutes)分\(rest)秒"
    }
}
