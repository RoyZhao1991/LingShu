import Foundation

/// **maker session ≠ checker session(用户硬性要求 2026-06-25)** 的执行接线。
///
/// 背景:派发的隔离任务用 `LingShuNestedAgentSession`,`verifyAndContinue` 对 nested session **直接返回**
/// (只有同会话内确定性逐阶段自查),没有独立 checker——当 maker 换成外部 agent(@Codex)后,这等于
/// 「编排脑自验」,违背 maker≠checker。本子域补上:agent-maker 任务收尾后,由**独立 checker**复核:
/// - checker 是另一个 agent(如 @Claude)→ 让它真去 run 一遍做跨厂商复核;
/// - 否则用**异源审查员**(`verifyAgentDeliverable` 走 cross-source `checkerAdapter`)。
/// 复核作为任务时间线里的**命名角色卡**可见(对齐 ARCHITECTURE.md §Task Journal「被调用 agent 的发言式进度」
/// + §Review「只展示真实参与者」+ 差距6 可见 checker);不过则退回 maker 修(有界轮次)。编排脑只委托,不当最终验收方。
@MainActor
extension LingShuState {

    /// agent-maker 派发任务收尾后跑独立 checker。非 agent-maker(本地脑 maker)任务原样返回,走原有验收链路。
    func runIndependentAgentCheckerIfNeeded(recordID: String?,
                                            makerResult: LingShuAgentRunResult,
                                            objective: String) async -> LingShuAgentRunResult {
        guard let rid = recordID,
              let binding = taskReviewBindings[rid],
              binding.maker.kind == .externalCLI,           // 只对「外部 agent 当 maker」的任务补独立 checker
              case .completed = makerResult else { return makerResult }

        let makerAgentID = String(binding.maker.id.dropFirst("external:".count))
        let checkerIsAgent = binding.checker.kind == .externalCLI
        let checkerAgentID = checkerIsAgent ? String(binding.checker.id.dropFirst("external:".count)) : ""
        let maxRounds = 2          // maker↔checker 返工的安全天花板(有界,不无限返工)
        var round = 0
        var current = makerResult

        while round < maxRounds {
            if Task.isCancelled || batchInterruptRequested { break }   // 全程可打断
            let makerText = Self.runResultText(current)

            let passed: Bool
            let critique: String
            if checkerIsAgent, let checkerPlugin = LingShuAgentPluginStore.plugin(id: checkerAgentID) {
                // ── 独立 agent(如 Claude)跨厂商复核:它是一条**独立会话**,真去读文件/跑测试再下结论。
                appendTaskRecordMessage(rid, actor: checkerPlugin.displayName, role: "验收(checker)·受灵枢委托", kind: .agent,
                    text: "▶ \(checkerPlugin.displayName) 独立复核 \(binding.maker.providerLabel)(maker)的产出——maker≠checker,跨厂商。")
                appendTrace(kind: .tool, actor: "独立验收·\(checkerPlugin.displayName)", title: "复核中", detail: String(objective.prefix(50)))
                let reviewObj = """
                你是独立验收方(checker)。另一个 agent(\(binding.maker.providerLabel),maker)针对目标完成了开发,产物在当前工作目录。
                目标:\(objective)
                请独立核验:真实读文件 / 跑测试 / 运行起来,判断是否达成目标。**只验收,别替它重写。**
                结论格式:第一行只写「通过」或「不通过」,其后逐条列问题。
                maker 自述产出:
                \(makerText.prefix(1500))
                """
                switch await LingShuAgentPluginStore.run(checkerPlugin, objective: reviewObj, workingDirectory: agentWorkingDirectory) {
                case .completed(let t): critique = t
                case .failure(let f):   critique = "(checker 未能完成复核:\(f))"
                }
                passed = Self.checkerVerdictPassed(critique)
                appendTaskRecordMessage(rid, actor: checkerPlugin.displayName,
                    role: passed ? "验收(checker)·通过" : "验收(checker)·需修正(第\(round + 1)轮)",
                    kind: passed ? .result : .agent, text: String(critique.prefix(1500)))
            } else {
                // ── 异源审查员:**先自己真跑一遍测试**(不信 maker 自报的"全绿"——maker 在自己 session 跑的测试输出没进任务记录,
                // 确定性验收门看不到 → 否则会一直判"构建完成不算交付"死循环)。把 checker 独立执行的测试结果记成 run_command 证据,
                // 再走同一确定性验收器(`checkerAdapter` 取**异源于 maker** 的本地脑,maker=codex → checker=GLM,真跨厂商)。
                await checkerIndependentlyRunsTests(recordID: rid, makerText: makerText)
                let (p, c) = await verifyAgentDeliverable(userRequest: objective, reply: makerText, taskRecordID: rid)
                passed = p; critique = c
                appendTaskRecordMessage(rid, actor: "审查员",
                    role: passed ? "验收(checker)·通过" : "验收(checker)·需修正(第\(round + 1)轮)",
                    kind: passed ? .result : .agent,
                    text: passed ? "🧑‍⚖️ 独立审查(\(binding.checker.providerLabel),异源于 maker \(binding.maker.providerLabel)):✅ 通过——产出真实落地、达成目标。"
                                 : "🧑‍⚖️ 独立审查(\(binding.checker.providerLabel)):⚠️ 需修正 — \(String(critique.prefix(400)))")
            }
            appendTrace(kind: passed ? .result : .warning, actor: "独立验收",
                        title: passed ? "通过" : "需修正(第\(round + 1)轮)",
                        detail: "maker:\(binding.maker.providerLabel) · checker:\(binding.checker.providerLabel)（异源）")

            if passed { return current }

            round += 1
            if round >= maxRounds {
                return .maxTurnsReached(lastText: makerText + "\n\n(独立验收 \(round) 轮仍未通过:\(critique.prefix(160))。先交还——需要你的判断。)")
            }
            // ── 不过 → 退回 maker 自己改(再委托一次,带上验收意见),checker 再验。maker 改、checker 验,各司其职。
            guard let makerPlugin = LingShuAgentPluginStore.plugin(id: makerAgentID) else { return current }
            appendTaskRecordMessage(rid, actor: makerPlugin.displayName, role: "开发(maker)·返工(第\(round)轮)", kind: .agent,
                                    text: "▶ 据独立验收意见返工:\(critique.prefix(160))")
            let fixObj = "你之前针对目标「\(objective)」的开发未通过独立验收。验收意见:\n\(critique.prefix(800))\n请据此修正,产物落到当前工作目录,确保真能跑通。"
            switch await LingShuAgentPluginStore.run(makerPlugin, objective: fixObj, workingDirectory: agentWorkingDirectory) {
            case .completed(let t):
                current = .completed(text: t)
                appendTaskRecordMessage(rid, actor: makerPlugin.displayName, role: "开发(maker)·返工交付", kind: .result, text: String(t.prefix(1500)))
            case .failure(let f):
                appendTaskRecordMessage(rid, actor: makerPlugin.displayName, role: "开发(maker)·返工失败", kind: .warning, text: f)
                return current
            }
        }
        return current
    }

    /// 独立 checker **自己真跑测试**(不信 maker 自报的"全绿"):据 maker 落盘的测试文件选测试运行器真执行,
    /// 把输出记成 `run_command` 证据进任务记录——确定性验收门(`codeTaskTestEvidence`/`codeTaskHasVisibleRunOutput`)
    /// 据此看到的是 **checker 独立验证的真实结果**,而非 maker 一面之词。这是 maker≠checker 真落地的关键一环。
    /// 暂支持 python pytest(覆盖 E2E + 最常见);其它语言留扩展(没识别到则跳过,交 verifyAgentDeliverable 其它维度)。
    @discardableResult
    private func checkerIndependentlyRunsTests(recordID rid: String, makerText: String) async -> Bool {
        var paths = Set(Self.extractFilePaths(from: makerText))
        if let arts = taskExecutionRecords.first(where: { $0.id == rid })?.artifacts { paths.formUnion(arts.map(\.location)) }
        let testFiles = paths.filter { FileManager.default.fileExists(atPath: $0) && Self.looksLikeTestFile($0) && Self.isTestableCodePath($0) }
        let pyTests = testFiles.filter { ($0 as NSString).pathExtension.lowercased() == "py" }.sorted()
        guard !pyTests.isEmpty else { return false }   // 没识别到可自动跑的测试 → 交给验收器其它维度,不强行
        let cmd = "python3 -m pytest \(pyTests.map { "'\($0)'" }.joined(separator: " ")) -q"
        appendTaskRecordMessage(rid, actor: "审查员", role: "验收(checker)·独立执行验证", kind: .review,
            text: "🧑‍⚖️ 不信 maker 自报,独立跑一遍测试:`\(cmd)`",
            detail: .toolCall(tool: "run_command", summary: cmd, arguments: cmd))
        let r = await toolExecutor.execute(.init(tool: "run_command", arguments: ["command": cmd]),
                                           workingDirectory: agentWorkingDirectory, allowShell: true)
        appendTaskRecordMessage(rid, actor: "审查员", role: r.success ? "验收(checker)·独立测试全绿" : "验收(checker)·独立测试有失败", kind: .review,
            text: String(r.output.suffix(700)),
            detail: .toolResult(tool: "run_command", success: r.success, output: r.output))
        appendTrace(kind: r.success ? .result : .warning, actor: "独立验收",
                    title: r.success ? "独立跑测试·全绿" : "独立跑测试·有失败", detail: String(r.output.suffix(80)))
        return true
    }

    /// **独立 checker 会话(用户定调 2026-06-26:maker/checker 必须是两个独立 session,哪怕都是 GLM)**。
    /// 起一个与 maker **完全独立**的 agent 会话,**从启动就被赋予「验收官」角色**——它主动 read_file 看代码、
    /// run_command 跑测试 / 把程序运行起来,独立核验产出是否真达成目标,给「通过/不通过」结论。
    /// 它看不到 maker 的内部过程,只面对落盘产出——这才是真 LOOP(maker 干活、checker 独立验,两条会话各司其职)。
    /// 异源与否取决于配了几档脑(配了第二档=真异源;单脑=同 GLM 两个独立会话/上下文)。
    func runCheckerSession(recordID rid: String, objective: String, makerText: String) async -> (passed: Bool, critique: String) {
        let adapter = checkerAdapter(taskRecordID: rid)   // 异源脑(配了的话)否则当前脑——但都是**独立会话**
        let verifyToolNames: Set<String> = ["read_file", "list_directory", "run_command"]
        let tools = agentBuiltinTools(recordIDProvider: { rid }, executionPolicy: dispatchedTaskExecutionPolicy)
            .filter { verifyToolNames.contains($0.name) }
        let system = """
        你是**独立验收官(checker)**,与开发方(maker)是**两条完全独立的会话**。你看不到 maker 的内部过程,只面对它落盘的产出。
        职责:独立核验产出**是否真达成目标**——主动 `read_file` 看代码、`run_command` 跑测试 / 把程序运行起来,逐条对成功标准核对。
        **铁律:只验收,绝不替它改 / 写任何代码或文件。** 结论:**第一行只写「通过」或「不通过」**,其后列依据(你跑了什么、看到什么)。
        """
        appendTaskRecordMessage(rid, actor: "审查员", role: "验收(checker)·独立会话上岗", kind: .agent,
            text: "🧑‍⚖️ 独立 checker 会话上岗(与 maker 不同会话/上下文),开始独立核验产出——读代码、跑测试、运行起来。")
        appendTrace(kind: .tool, actor: "checker会话", title: "独立验收会话上岗", detail: String(objective.prefix(50)))
        let session = makeAgentSession(id: "checker-\(UUID().uuidString.prefix(6))", system: system,
                                       tools: tools, model: adapter, maxTurns: 30)
        let task = """
        目标:\(objective)
        maker 自述它的产出(仅供参考,务必独立核实、别轻信):
        \(makerText.prefix(1500))
        产物在当前工作目录。请独立核验后给结论(第一行 通过/不通过)。
        """
        let verdict = Self.runResultText(await session.send(task))
        return (Self.checkerVerdictPassed(verdict), verdict)
    }

    /// checker 文本结论是否判过(纯函数可测):第一行「通过」/pass 算过;「不通过」/not pass/fail 一律不过。
    nonisolated static func checkerVerdictPassed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(trimmed.prefix(40))
        let lowerHead = head.lowercased()
        if head.contains("不通过") || head.contains("未通过") || lowerHead.contains("not pass") || lowerHead.contains("fail") { return false }
        if head.contains("通过") || lowerHead.contains("pass") || head.contains("✅") { return true }
        // 兜底:整体含明确通过信号且无失败信号。
        return (trimmed.contains("验收通过") || text.lowercased().contains("all tests pass"))
            && !trimmed.contains("未通过") && !trimmed.contains("不通过")
    }
}
