import Foundation

/// 通用中枢 P2·能力缺口分析**接线**(见 `Docs/通用AI中枢推进方案.md`)。
/// 执行前据「能力快照 + 自我扩展元能力」评估目标可行性、指出缺口 + 补齐路径,**绑定任务记录** →
/// `driveAgentDelivery` 注入执行引导(先补齐再推进)。与 P1 GoalSpec 同属前置认知,共用开关 `goalSpecEnabled`。
@MainActor
extension LingShuState {

    /// 据一条请求 + 当前能力快照派生能力缺口分析(模型 1-shot、无工具),落 trace。返回结果(失败 nil)。
    /// **不硬阻断**:有缺口也只是注入引导让大脑先按补齐路径取得能力,真补不了则如实告知用户。
    @discardableResult
    func deriveGapAnalysis(for request: String) async -> LingShuGapAnalysis? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let snapshot = capabilitySnapshot()
        let session = LingShuAgentSession(
            id: "gap-\(UUID().uuidString.prefix(6))",
            system: LingShuGapAnalyzer.systemPrompt(capabilities: snapshot),
            tools: [], model: controlPlaneModelAdapter(.gapAnalysis), maxTurns: 1
        )
        guard case .completed(let text) = await session.send(trimmed) else { return nil }
        guard let analysis = LingShuGapAnalyzer.parse(LingShuReasoningText.stripThinkTags(text)) else {
            appendTrace(kind: .system, actor: "能力评估", title: "缺口分析解析失败",
                        detail: "模型未产出可解析的评估(本回合按无缺口评估执行,不影响)。")
            return nil
        }
        let title = analysis.feasibleNow && analysis.gaps.isEmpty ? "能力足够" : (analysis.hasBlockingGap ? "有阻断缺口" : "缺口可自补")
        appendTrace(kind: .system, actor: "能力评估", title: title, detail: analysis.summary)
        return analysis
    }

    /// 把缺口分析绑定为记录的 typed 字段(持久化)+ 落记录时间线(有缺口才落,免噪声)。
    func bindGapAnalysis(_ analysis: LingShuGapAnalysis?, to recordID: String) {
        guard let analysis, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[idx].gapAnalysis = analysis
        if !analysis.gaps.isEmpty {
            appendTaskRecordMessage(recordID, actor: "能力评估", role: "缺口", kind: .core, text: analysis.summary)
        } else {
            persistTaskExecutionRecords()
        }
    }

    /// 取某任务记录的 typed 缺口分析(单一真相 = 记录字段,跨重启可用)。
    func gapAnalysis(for recordID: String?) -> LingShuGapAnalysis? {
        guard let recordID else { return nil }
        return taskExecutionRecords.first(where: { $0.id == recordID })?.gapAnalysis
    }

    /// P2 覆盖对齐:**已知是 task 型目标**的入口(自主真实目标 / spawn 子任务)统一前置认知——
    /// 并发派生 GoalSpec + 能力缺口分析并绑定记录(与主输入 task 路径同款消费:执行引导/验收/经验)。
    /// GoalSpec 解析失败给最小兜底(objective=原请求);gap 失败则不绑(按无缺口)。已绑过则不重派(幂等)。
    func bindPreflightCognition(request: String, recordID: String) async {
        guard goalSpecEnabled else { return }
        async let specF = deriveGoalSpec(for: request, taskRecordID: nil)
        async let gapF = deriveGapAnalysis(for: request)
        async let reqF = deriveCapabilityRequirements(for: request)   // P2 真闭环:通用能力需求(查图谱)
        let spec = await specF
        let analysis = await gapF
        let reqs = await reqF
        if goalSpec(for: recordID) == nil {
            bindGoalSpec(spec ?? LingShuGoalSpec(objective: request, kind: .task,
                         successCriteria: ["完成并可验证目标:\(String(request.prefix(60)))"]), to: recordID)
        }
        if gapAnalysis(for: recordID) == nil { bindGapAnalysis(analysis, to: recordID) }
        bindCapabilityRequirements(reqs, to: recordID)
    }
}
