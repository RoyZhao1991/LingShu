import Foundation

/// 通用中枢 P1·目标认知**接线**(见 `Docs/通用AI中枢推进方案.md`)。
/// **P1 完全落地**:入口(`submitTextInput` 分诊之前)派生 `LingShuGoalSpec` 并存 `goalSpecsByRecord`,
/// 由 ① `driveAgentDelivery` 注入执行引导(循环消费)② `verifyAgentDeliverable` 引用成功标准(验收消费)
/// ③ 任务记录落痕(记忆消费)。开关 `lingshu.goalSpec`(DEBUG 默认开)。
@MainActor
extension LingShuState {

    /// 目标认知开关:**默认开(发布态亦然=完整可用)**;配置入口 `setGoalSpecEnabled` / MCP `lingshu_set_goalspec` 可关。
    /// 关 → 零行为/零成本变更(不发那次解析模型调用、不注入引导/成功标准/不沉淀经验)。状态见 `lingshu_status.goalSpecEnabled`。
    var goalSpecEnabled: Bool {
        UserDefaults.standard.object(forKey: "lingshu.goalSpec") as? Bool ?? true
    }

    /// 配置入口:开/关目标认知(持久化 UserDefaults,跨重启)。供 MCP `lingshu_set_goalspec` / 设置 UI 调用。
    func setGoalSpecEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "lingshu.goalSpec")
        appendTrace(kind: .system, actor: "目标认知", title: on ? "已开启" : "已关闭",
                    detail: on ? "每个新顶层目标先结构化理解(GoalSpec)→ 注入执行引导/验收成功标准/沉淀经验。"
                               : "已关闭:零成本零行为变更。")
    }

    /// 从一条用户请求派生 GoalSpec(模型 1-shot、无工具),落 trace。返回解析结果(失败 nil)。
    /// 调用方拿到后存 `goalSpecsByRecord[记录]` → 供执行引导/验收成功标准/记忆消费。
    @discardableResult
    func deriveGoalSpec(for request: String, taskRecordID: String?) async -> LingShuGoalSpec? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let adapter = makeAgentModelAdapter()
        let session = LingShuAgentSession(
            id: "goalspec-\(UUID().uuidString.prefix(6))",
            system: LingShuGoalSpecParser.systemPrompt,
            tools: [], model: adapter, maxTurns: 1
        )
        guard case .completed(let text) = await session.send(trimmed) else { return nil }
        guard let spec = LingShuGoalSpecParser.parse(LingShuReasoningText.stripThinkTags(text)) else {
            appendTrace(kind: .system, actor: "目标认知", title: "GoalSpec 解析失败",
                        detail: "模型未产出可解析的目标规格(本回合按无目标规格执行,不影响)。")
            return nil
        }
        appendTrace(kind: .system, actor: "目标认知", title: "GoalSpec", detail: spec.summary)
        return spec
    }

    /// 把派生好的 GoalSpec **绑定为记录的 typed 字段**(随记录持久化跨重启)+ 落记录时间线。
    /// 记录是单一真相:执行引导/验收/记忆都从 `goalSpec(for:)` 读它,重启后链路仍拿得到 typed 值。
    func bindGoalSpec(_ spec: LingShuGoalSpec?, to recordID: String) {
        guard let spec, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[idx].goalSpec = spec
        appendTaskRecordMessage(recordID, actor: "目标认知", role: "目标", kind: .core, text: spec.summary)
    }

    /// 取某任务记录的 typed GoalSpec(单一真相 = 记录字段,跨重启可用)。
    func goalSpec(for recordID: String?) -> LingShuGoalSpec? {
        guard let recordID else { return nil }
        return taskExecutionRecords.first(where: { $0.id == recordID })?.goalSpec
    }

    /// P1·**记忆消费(结构化经验沉淀)**:目标到终态时,把「目标→成功标准→结果→产出/失败原因」蒸成一条
    /// **可检索经验**入知识图谱(陈述句、过去式,经纪律闸 + 园丁去重)。下次同类目标 `recall_memory`/seed 即接续历史经验。
    /// 只沉淀终态(完成/直答/未达标),blocked/暂停不沉淀(未定论)。无 GoalSpec(开关关或非新目标)则空跑。
    func rememberGoalExperienceIfNeeded(recordID: String, status: LingShuTaskExecutionStatus) {
        guard let rec = taskExecutionRecords.first(where: { $0.id == recordID }), let spec = rec.goalSpec else { return }
        let outcome: String
        switch status {
        case .completed: outcome = "已完成"
        case .verified:  outcome = "已核验完成"
        case .answered:  outcome = "已直接回答"
        case .needsRevision: outcome = "未达标"
        case .partial:   outcome = "部分完成"
        case .failed:    outcome = "失败"
        default: return   // 排队/执行/就绪/待用户/补齐中/暂停/阻断:非终态或无定论,不沉淀
        }
        var body = "经验:目标「\(spec.objective)」(\(spec.kind.rawValue))结果=\(outcome)。"
        if !spec.successCriteria.isEmpty { body += "成功标准:\(spec.successCriteria.joined(separator: ";"))。" }
        let artifacts = rec.artifacts.map(\.location).prefix(3)
        if !artifacts.isEmpty { body += "产出:\(artifacts.joined(separator: "、"))。" }
        // P2 真闭环:沉淀能力缺口与补齐过程(缺了什么、试了哪些路径、成败、成功能力如何复用)。
        if let attempts = rec.acquisitionAttempts, !attempts.isEmpty {
            let parts = attempts.map { "「\($0.capability)」经\($0.path)→\($0.outcome.rawValue)" }
            body += "能力补齐:\(parts.joined(separator: ";"))。"
            if attempts.contains(where: { $0.outcome == .acquiredVerified }) {
                body += "(已补齐的能力已入图谱,下次同类目标可直接复用。)"
            }
        }
        if outcome == "未达标", !rec.summary.isEmpty { body += "未达标小结:\(rec.summary.prefix(120))。" }
        _ = knowledgeGraph.remember(.init(kind: .fact, title: String(spec.objective.prefix(60)),
                                          body: body, source: .inference, confidence: 0.5))
        appendTrace(kind: .result, actor: "经验沉淀", title: "目标经验入图谱", detail: String(body.prefix(80)))
    }
}
