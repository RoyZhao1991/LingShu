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
              // 外部 agent 当 **maker**(@Codex 开发)或当 **checker**(灵枢开发 + @Codex 验收)都要走独立 checker。
              binding.maker.kind == .externalCLI || binding.checker.kind == .externalCLI,
              case .completed = makerResult else { return makerResult }

        let makerIsExternal = binding.maker.kind == .externalCLI
        let makerAgentID = makerIsExternal ? String(binding.maker.id.dropFirst("external:".count)) : ""   // 本地脑 maker 无插件,不重委托
        let checkerIsAgent = binding.checker.kind == .externalCLI
        let checkerAgentID = checkerIsAgent ? String(binding.checker.id.dropFirst("external:".count)) : ""
        let maxRounds = 2          // maker↔checker 返工的安全天花板(有界,不无限返工)
        var round = 0
        var current = makerResult
        let extraCheckerIDs = taskExtraCheckerAgentIDs[rid] ?? []   // **多 checker**:主 checker 之外的额外 agent

        // 跑单个 agent checker(独立会话:它自己读文件/跑测试),记参与方 + 结论。
        func runAgentChecker(_ plugin: LingShuAgentPlugin, makerText: String, round: Int) async -> (passed: Bool, critique: String) {
            appendTrace(kind: .tool, actor: "独立验收·\(plugin.displayName)", title: "复核中", detail: String(objective.prefix(50)))
            // 修 1a:给外部 agent checker 也带上产出物真实绝对路径,别只说"在工作目录"(同 runCheckerSession 根因)。
            let artPaths = (taskExecutionRecords.first { $0.id == rid }?.artifacts ?? []).map(\.location)
            let artHint = artPaths.isEmpty ? "产物应在工作目录 \(agentWorkingDirectory)。"
                : "产出物绝对路径(直接核验这些具体文件):\n" + artPaths.map { "- \($0)" }.joined(separator: "\n")
            let reviewObj = "你是独立验收方(checker)。maker 针对目标完成了开发。\n目标:\(objective)\n工作目录:\(agentWorkingDirectory)\n\(artHint)\n请独立核验:真实读文件 / 跑测试 / 运行起来,判断是否达成目标。**只验收,别替它重写。**\n结论格式:第一行只写「通过」或「不通过」,其后逐条列问题。\nmaker 自述产出:\n\(makerText.prefix(1500))"
            let c: String
            // **流式**:边跑边把 checker 的复核进展更新进同一条参与方气泡(不再干等)。
            switch await runAgentStreamingToRecord(plugin, objective: reviewObj, recordID: rid,
                                                   actor: plugin.displayName, role: "验收(checker)·受灵枢委托",
                                                   startText: "▶ \(plugin.displayName) 独立复核产出(maker≠checker)。") {
            case .completed(let t): c = t
            case .failure(let f):   c = "(checker 未能完成复核:\(f))"
            }
            let p = Self.checkerVerdictPassed(c)
            appendTaskRecordMessage(rid, actor: plugin.displayName,
                role: p ? "验收(checker)·通过" : "验收(checker)·需修正(第\(round + 1)轮)",
                kind: p ? .result : .agent, text: String(c.prefix(1500)))
            return (p, c)
        }

        while round < maxRounds {
            if Task.isCancelled || batchInterruptRequested { break }   // 全程可打断
            let makerText = Self.runResultText(current)
            var verdicts: [(name: String, passed: Bool, critique: String)] = []   // 每个 checker 一条(多 checker 聚合)

            // 主 checker:外部 agent → 它;否则异源审查员(GLM,先自己跑测试再判)。
            if checkerIsAgent, let primary = LingShuAgentPluginStore.plugin(id: checkerAgentID) {
                let (p, c) = await runAgentChecker(primary, makerText: makerText, round: round)
                verdicts.append((primary.displayName, p, c))
            } else {
                await checkerIndependentlyRunsTests(recordID: rid, makerText: makerText)
                let (p, c) = await verifyAgentDeliverable(userRequest: objective, reply: makerText, taskRecordID: rid)
                appendTaskRecordMessage(rid, actor: "审查员",
                    role: p ? "验收(checker)·通过" : "验收(checker)·需修正(第\(round + 1)轮)",
                    kind: p ? .result : .agent,
                    text: p ? "🧑‍⚖️ 独立审查(\(binding.checker.providerLabel),异源于 maker \(binding.maker.providerLabel)):✅ 通过——产出真实落地、达成目标。"
                            : "🧑‍⚖️ 独立审查(\(binding.checker.providerLabel)):⚠️ 需修正 — \(String(c.prefix(400)))")
                verdicts.append(("审查员", p, c))
            }
            // **额外 checker(多 checker:多个 agent 同时验,各自独立会话、各自一条命名角色卡)**
            for id in extraCheckerIDs {
                if let plugin = LingShuAgentPluginStore.plugin(id: id) {
                    let (p, c) = await runAgentChecker(plugin, makerText: makerText, round: round)
                    verdicts.append((plugin.displayName, p, c))
                }
            }

            let allPassed = verdicts.allSatisfy { $0.passed }
            let combined = verdicts.filter { !$0.passed }.map { "【\($0.name)】\($0.critique.prefix(300))" }.joined(separator: "\n")
            appendTrace(kind: allPassed ? .result : .warning, actor: "独立验收",
                        title: allPassed ? "全部 checker 通过" : "需修正(第\(round + 1)轮)",
                        detail: verdicts.map { "\($0.name):\($0.passed ? "✅" : "✗")" }.joined(separator: " "))

            if allPassed { return current }

            round += 1
            if round >= maxRounds {
                return .maxTurnsReached(lastText: makerText + "\n\n(独立验收 \(round) 轮仍未全过:\(combined.prefix(200))。先交还——需要你的判断。)")
            }
            // ── 不过 → 退回 maker 自己改(带上**所有未过 checker** 的合并意见),checker 再验。
            // 本地脑 maker(灵枢自己开发 + 外部 agent 当 checker)无插件可重委托 → 如实交还,等主人/灵枢据意见再修。
            guard makerIsExternal, let makerPlugin = LingShuAgentPluginStore.plugin(id: makerAgentID) else {
                return .maxTurnsReached(lastText: makerText + "\n\n(独立 checker 判未通过:\(combined.prefix(200))。本地 maker 已交还——需据意见修正后重验。)")
            }
            let fixObj = "你之前针对目标「\(objective)」的开发未通过独立验收。验收意见:\n\(combined.prefix(800))\n请据此修正,产物落到当前工作目录,确保真能跑通。"
            // **流式**:maker 返工也边跑边更新气泡(不再干等)。
            switch await runAgentStreamingToRecord(makerPlugin, objective: fixObj, recordID: rid,
                                                   actor: makerPlugin.displayName, role: "开发(maker)·返工(第\(round)轮)",
                                                   startText: "▶ 据独立验收意见返工:\(combined.prefix(200))") {
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
        // **修 1a(2026-06-27)**:给 checker **产出物的真实绝对路径**——别只说"在工作目录"。
        // 否则产物在工作目录之外(maker 用绝对路径写到别处)或 list_directory 列空时,checker 找不到文件 → 瞎判"不存在"=假否决
        // (实测:checker 在 HOME list_directory 列空,而产物在 /app 子目录,直接判 PPT 不存在)。给了绝对路径它就能 read_file 核真文件。
        let artifactPaths = (taskExecutionRecords.first { $0.id == rid }?.artifacts ?? []).map(\.location)
        let artifactHint = artifactPaths.isEmpty
            ? "产物应在工作目录 \(agentWorkingDirectory)(若 list_directory 列空,maker 可能没真落盘=本身就是问题)。"
            : "maker 落盘的产出物**绝对路径**(直接 `read_file`/`run_command` 核验这些具体文件,别只 list_directory 工作目录):\n"
              + artifactPaths.map { "- \($0)" }.joined(separator: "\n")
        let task = """
        目标:\(objective)
        工作目录:\(agentWorkingDirectory)
        \(artifactHint)
        maker 自述它的产出(仅供参考,务必独立核实、别轻信):
        \(makerText.prefix(1500))
        请独立核验后给结论(第一行 通过/不通过)。
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
