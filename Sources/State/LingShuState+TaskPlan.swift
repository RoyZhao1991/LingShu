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
            guard !steps.isEmpty else {
                lingShuControlLog("update_plan parse EMPTY; raw args=\(argsJSON.prefix(500))")
                // 计划是可选脚手架,不是任务本身。解析失败别让模型死磕格式——直接steer它跳过、去做真正的事。
                return "计划没解析到步骤(格式可参考 {\"steps\":[{\"title\":\"第一步\"}]})。但**计划是可选的,别卡在这里**——如果再传一次还不行,就直接用 write_file/run_command 等开始做任务本身,完成后给结果。"
            }
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
        // 计划一更新就把加载气泡刷成"当前在做的步骤"(进行中→待办),让进度显示活动而非"思考中"。
        if recordID == (currentAgentTurnRecordID ?? autonomousRunRecordID), isModelReplying || isAutonomousRunActive {
            missionTitle = currentActivityLabel
        }
    }

    /// 解析 update_plan 参数为计划步骤(纯函数,可测)。
    ///
    /// **鲁棒**:不同模型对数组参数的序列化五花八门——曾因只认 `{steps:[{title,status}]}` 一种形状,
    /// 别的模型传**纯字符串数组**(`{steps:["第一步",...]}`)/**把数组当字符串再编码一遍**(`{steps:"[...]"}`)/
    /// **顶层就是数组**/换了键名(plan/items/tasks)/换了标题键(step/name/text)→ 一律解析失败回"计划为空",
    /// 模型反复试都失败遂**放弃计划**,LOOP 先计划后执行形同虚设。这里把这些常见形状全吃下。
    nonisolated static func parsePlanSteps(_ json: String) -> [LingShuPlanStep] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let obj = root as? [String: Any] {
            for key in ["steps", "plan", "items", "tasks", "todos"] {
                let parsed = stepsFromAny(obj[key])
                if !parsed.isEmpty { return parsed }
            }
            return []
        }
        return stepsFromAny(root)   // 顶层直接是数组
    }

    /// 把任意形状的"步骤值"归一成计划步骤:对象数组 / 纯字符串数组 / 混合数组 / 内嵌 JSON 字符串。
    private nonisolated static func stepsFromAny(_ any: Any?) -> [LingShuPlanStep] {
        guard let any else { return [] }
        if let arr = any as? [Any] {
            return arr.compactMap { element in
                if let obj = element as? [String: Any] { return planStep(fromObject: obj) }
                if let str = element as? String {
                    let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : LingShuPlanStep(title: t, status: .pending)
                }
                return nil
            }
        }
        // 整个数组被当成字符串又编码了一遍 → 再解一层。
        if let str = any as? String, let data = str.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: data) {
            return stepsFromAny(inner)
        }
        return []
    }

    private nonisolated static func planStep(fromObject item: [String: Any]) -> LingShuPlanStep? {
        let titleRaw = (item["title"] as? String) ?? (item["step"] as? String)
            ?? (item["name"] as? String) ?? (item["text"] as? String) ?? (item["content"] as? String)
        guard let title = titleRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let raw = (item["status"] as? String ?? "pending").lowercased()
        let status: LingShuPlanStep.Status
        if raw.contains("progress") || raw.contains("进行") || raw.contains("doing") || raw.contains("current") {
            status = .inProgress
        } else if raw.contains("complete") || raw.contains("done") || raw.contains("完成") || raw.contains("finish") {
            status = .completed
        } else {
            status = .pending
        }
        return LingShuPlanStep(title: title, status: status)
    }

    /// 人类可读的总用时(供回复末尾"总用时"展示)。
    nonisolated static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)秒" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes)分" : "\(minutes)分\(rest)秒"
    }
}
