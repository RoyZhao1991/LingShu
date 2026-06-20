import Foundation

/// 内置「脑力测试」运行器:把硬编码题库逐题发给**当前脑**作答 → 确定性判分 → 综合评分 → 弹窗结果。
/// 纯题库/判分/算分在 `LingShuBrainBenchmark`(可单测);这里只做"驱动当前脑跑题 + 汇总"。
@MainActor
extension LingShuState {

    private static let benchSystem = "你正在参加一次脑力测评。严格按每道题的要求作答,要简洁、直接给答案;题目要你'只回答数字/一个字/只输出JSON'时就别多说。"

    /// 跑完整套脑力测试(逐题真发给当前脑),产出综合评分并置入 `brainBenchmarkResult`(触发弹窗)。
    /// 全程可被 `isRunningBrainBenchmark` 观察(按钮转圈);单题失败不影响整套(算 0 分继续)。
    func runBrainBenchmark() async {
        guard !isRunningBrainBenchmark else { return }
        isRunningBrainBenchmark = true
        appendTrace(kind: .system, actor: "脑力测试", title: "开始", detail: "共 \(LingShuBrainBenchmark.items.count) 题(当前脑 \(currentBrainID))")
        defer { isRunningBrainBenchmark = false }

        var passed: Set<String> = []
        var rows: [LingShuBrainBenchmarkResult.Row] = []
        for item in LingShuBrainBenchmark.items {
            if Task.isCancelled { break }
            // agentic 题给**真工具**(autoAllowShell 免审批弹窗)+ 更多轮,逼它真驱动工具循环;reasoning 题无工具单轮。
            let tools = item.agentic ? agentBuiltinTools(recordIDProvider: { nil }, executionPolicy: .autoAllowShell) : []
            let session = LingShuAgentSession(
                id: "bench-\(item.id)-\(UUID().uuidString.prefix(4))",
                system: Self.benchSystem, tools: tools,
                model: makeAgentModelAdapter(), maxTurns: item.maxTurns)
            let result = await session.send(item.prompt)
            let reply = LingShuReasoningText.stripThinkTags(Self.runResultText(result)).trimmingCharacters(in: .whitespacesAndNewlines)
            let usedTools = await !session.toolInvocations.isEmpty   // 真调过工具吗(agentic 判分要求它=真,治"摆烂/口算")
            let ok = item.grade(reply, usedTools)
            if ok { passed.insert(item.id) }
            rows.append(.init(itemID: item.id, title: item.title, difficulty: item.difficulty.label, agentic: item.agentic, passed: ok, replyExcerpt: String(reply.prefix(60))))
            appendTrace(kind: ok ? .result : .warning, actor: "脑力测试", title: "\(item.title)[\(item.difficulty.label)\(item.agentic ? "·工具" : "")] \(ok ? "✓" : "✗")", detail: "\(item.agentic ? "调工具\(usedTools ? "是" : "否") · " : "")\(reply.prefix(36))")
        }

        let score = LingShuBrainBenchmark.composite(passedIDs: passed)
        let out = LingShuBrainBenchmarkResult(
            brainID: currentBrainID, score: score,
            passedCount: passed.count, totalCount: LingShuBrainBenchmark.items.count, rows: rows)
        brainBenchmarkResult = out   // 非 nil → 弹窗
        appendTrace(kind: .result, actor: "脑力测试", title: "完成 · \(score)分(\(out.grade))", detail: "通过 \(passed.count)/\(LingShuBrainBenchmark.items.count) · 脑 \(currentBrainID)")
    }

    /// MCP 控制口子:跑脑力测试并返回综合分 JSON(供脚本化 E2E)。
    func controlRunBrainBenchmark() async -> (text: String, isError: Bool) {
        await runBrainBenchmark()
        let r = brainBenchmarkResult
        let rows = r?.rows.map { ["title": $0.title, "difficulty": $0.difficulty, "passed": $0.passed] as [String: Any] } ?? []
        let obj: [String: Any] = ["score": r?.score ?? 0, "passed": r?.passedCount ?? 0, "total": r?.totalCount ?? 0,
                                  "grade": r?.grade ?? "", "brain": r?.brainID ?? currentBrainID, "rows": rows]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}", false)
    }
}
