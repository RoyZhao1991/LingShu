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
        // 长链编码题在隔离 benchDir 里写代码(临时把工作目录指过去,让 write_file/run_command 都落这);跑完恢复+清理。
        let benchDir = NSTemporaryDirectory() + "lingshu-brainbench-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: benchDir, withIntermediateDirectories: true)
        let savedWorkdir = agentWorkingDirectory
        agentWorkingDirectory = benchDir
        defer {
            agentWorkingDirectory = savedWorkdir
            try? FileManager.default.removeItem(atPath: benchDir)
            isRunningBrainBenchmark = false
        }

        var fractions: [String: Double] = [:]   // 每题完成度(生产题=隐藏用例通过比例,部分给分)
        var passedCount = 0
        var rows: [LingShuBrainBenchmarkResult.Row] = []
        for item in LingShuBrainBenchmark.items {
            if Task.isCancelled { break }
            // agentic/编码题给**真工具**(autoAllowShell 免审批弹窗)+ 更多轮;reasoning 题无工具单轮。
            let tools = item.agentic ? agentBuiltinTools(recordIDProvider: { nil }, executionPolicy: .autoAllowShell) : []
            // 编码题:预置文件(扩展/调试题)+ 把 {DIR} 换成真路径。
            if let check = item.codeCheck {
                for (rel, content) in check.preWrite {
                    try? content.write(toFile: benchDir + "/" + rel, atomically: true, encoding: .utf8)
                }
            }
            let prompt = item.prompt.replacingOccurrences(of: "{DIR}", with: benchDir)
            let session = LingShuAgentSession(
                id: "bench-\(item.id)-\(UUID().uuidString.prefix(4))",
                system: Self.benchSystem, tools: tools,
                model: makeAgentModelAdapter(), maxTurns: item.maxTurns)
            let result = await session.send(prompt)
            let reply = LingShuReasoningText.stripThinkTags(Self.runResultText(result)).trimmingCharacters(in: .whitespacesAndNewlines)
            let usedTools = await !session.toolInvocations.isEmpty
            // 编码题:跑隐藏用例真验代码(支持 BENCH_SCORE p t 部分给分);其余题用回复判分(0/1)。
            var fraction = 0.0
            var scoreText = ""
            if let check = item.codeCheck {
                let (frac, p, t) = await runBenchCodeCheck(check, benchDir: benchDir)
                fraction = frac
                if t > 0 { scoreText = "\(p)/\(t)" }
            } else {
                fraction = item.grade(reply, usedTools) ? 1.0 : 0.0
            }
            fractions[item.id] = fraction
            let ok = fraction >= 0.999
            if ok { passedCount += 1 }
            rows.append(.init(itemID: item.id, title: item.title, difficulty: item.difficulty.label, agentic: item.agentic, passed: ok, scoreText: scoreText, replyExcerpt: String(reply.prefix(60))))
            let mark = ok ? "✓" : (fraction > 0 ? "◐\(scoreText)" : "✗")
            appendTrace(kind: ok ? .result : .warning, actor: "脑力测试", title: "\(item.title)[\(item.difficulty.label)\(item.agentic ? "·工具" : "")] \(mark)", detail: "\(item.codeCheck != nil ? "隐藏用例 \(scoreText.isEmpty ? (ok ? "全过" : "未过") : scoreText) · " : (item.agentic ? "调工具\(usedTools ? "是" : "否") · " : ""))\(reply.prefix(28))")
        }

        let score = LingShuBrainBenchmark.compositeWeighted(fractions)
        let out = LingShuBrainBenchmarkResult(
            brainID: currentBrainID, score: score,
            passedCount: passedCount, totalCount: LingShuBrainBenchmark.items.count, rows: rows,
            tiers: LingShuBrainBenchmark.tierBreakdown(fractions))
        brainBenchmarkResult = out   // 非 nil → 弹窗
        upsertBenchmarkSnapshot(out.snapshot)   // 存进跨脑对比历史(同脑覆盖最新)
        appendTrace(kind: .result, actor: "脑力测试", title: "完成 · \(score)分(\(out.grade))", detail: "全过 \(passedCount)/\(LingShuBrainBenchmark.items.count) · 脑 \(currentBrainID)")
    }

    /// 跑编码题隐藏用例:harness 写进 benchDir 用 python3 真跑。返回(完成度 0~1, 通过子项, 子项总数)。
    /// 支持两种判分:`BENCH_SCORE p t`=部分给分(p/t);`BENCH_PASS`=全过(1.0);其余=0。
    /// 模型写的解在 benchDir;harness 注入 `sys.path` 后 import 它们跑隐藏断言。
    private func runBenchCodeCheck(_ check: LingShuBrainBenchmark.CodeCheck, benchDir: String) async -> (fraction: Double, passed: Int, total: Int) {
        let harnessPath = benchDir + "/_bench_harness.py"
        let full = "import sys\nsys.path.insert(0, \(pyStr(benchDir)))\n" + check.harness
        guard (try? full.write(toFile: harnessPath, atomically: true, encoding: .utf8)) != nil else { return (0, 0, 0) }
        let out = await Self.runReadCommand("/usr/bin/python3", [harnessPath], timeout: 45)
        try? FileManager.default.removeItem(atPath: harnessPath)
        // BENCH_SCORE p t → 部分给分
        if let m = out.range(of: "BENCH_SCORE", options: .backwards) {
            let nums = out[m.upperBound...].split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
            if nums.count == 2, nums[1] > 0 { return (Double(nums[0]) / Double(nums[1]), nums[0], nums[1]) }
        }
        if out.contains("BENCH_PASS") { return (1.0, 1, 1) }
        return (0, 0, 0)
    }

    /// python 字符串字面量(给路径加引号转义,防特殊字符)。
    private func pyStr(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    // MARK: - 跨脑对比历史(持久化)

    nonisolated static let benchHistoryKey = "lingshu.brainBenchmarkHistory"

    /// 存一份测评快照(同 brainID 覆盖最新),供弹窗并排对比不同脑的各档水位。
    func upsertBenchmarkSnapshot(_ snap: LingShuBrainBenchmarkSnapshot) {
        brainBenchmarkHistory.removeAll { $0.brainID == snap.brainID }
        brainBenchmarkHistory.append(snap)
        brainBenchmarkHistory.sort { $0.score > $1.score }   // 高分在前,差距一目了然
        if let data = try? JSONEncoder().encode(brainBenchmarkHistory) {
            UserDefaults.standard.set(data, forKey: Self.benchHistoryKey)
        }
    }

    nonisolated static func loadBenchmarkHistory() -> [LingShuBrainBenchmarkSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: benchHistoryKey),
              let h = try? JSONDecoder().decode([LingShuBrainBenchmarkSnapshot].self, from: data) else { return [] }
        return h
    }

    /// MCP 控制口子:跑脑力测试并返回综合分 JSON(供脚本化 E2E)。
    func controlRunBrainBenchmark() async -> (text: String, isError: Bool) {
        await runBrainBenchmark()
        let r = brainBenchmarkResult
        let rows = r?.rows.map { ["title": $0.title, "difficulty": $0.difficulty, "passed": $0.passed, "score": $0.scoreText] as [String: Any] } ?? []
        let tiers = r?.tiers.map { ["tier": $0.label, "pct": $0.pct, "passed": $0.passed, "total": $0.total, "weight": $0.weight] as [String: Any] } ?? []
        let obj: [String: Any] = ["score": r?.score ?? 0, "passed": r?.passedCount ?? 0, "total": r?.totalCount ?? 0,
                                  "grade": r?.grade ?? "", "brain": r?.brainID ?? currentBrainID, "tiers": tiers, "rows": rows]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}", false)
    }
}
