import Foundation

/// 通用中枢 P3·**全类型验收**接线(见 `Docs/通用AI中枢推进方案.md` P3)。
/// 把 GoalSpec 的成功标准**分类型**(惰性分类一次后缓存到记录),验收时凡能确定性核验的(文件存在 / 命令·测试成功)
/// 用**文件系统 + 执行记录证据**裁决,不能的如实标 unverifiable(交 LLM/用户,绝不幻觉为已达成)。
/// 由 `verifyAgentDeliverable` 消费:任一确定性条 unmet → 硬门返工;其余注入评审官逐条核对。与 P1/P2 共用开关 `goalSpecEnabled`。
@MainActor
extension LingShuState {

    /// 据某任务记录算全类型验收报告:取 GoalSpec 成功标准 → 惰性分类(缓存)→ 用宿主侧事实逐条裁决。
    /// 无成功标准 / 开关关 → 空报告(不加压、零成本)。
    func acceptanceReport(taskRecordID: String?, realFiles: [String]) async -> LingShuAcceptanceReport {
        guard shouldRunGoalAcceptance(taskRecordID: taskRecordID),
              let spec = goalSpec(for: taskRecordID) else {
            return LingShuAcceptanceReport(verdicts: [], note: "")
        }
        // 分类:惰性、缓存到记录(返工循环里复用,不重复分类)。
        var checks = acceptanceChecks(for: taskRecordID)
        if checks == nil {
            let derived = await deriveAcceptanceChecks(criteria: spec.successCriteria)
            bindAcceptanceChecks(derived, to: taskRecordID)
            checks = derived
        }
        guard let checks, !checks.isEmpty else { return LingShuAcceptanceReport(verdicts: [], note: "") }
        return LingShuAcceptanceReport.make(
            checks: checks,
            fileExists: { [weak self] probe in self?.acceptanceFileExists(probe, realFiles: realFiles) ?? false },
            commandSucceeded: { [weak self] probe in (self?.commandProbeOutcome(probe, taskRecordID: taskRecordID)) ?? nil }
        )
    }

    /// 把成功标准分类成验收检查项(模型 1-shot、无工具)。解析失败 → 全部回退 content_quality(交评审官,不丢条目)。
    @discardableResult
    func deriveAcceptanceChecks(criteria: [String]) async -> [LingShuAcceptanceCheck] {
        let cleaned = criteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }
        let fallback = cleaned.map { LingShuAcceptanceCheck(kind: .contentQuality, criterion: $0, probe: nil) }
        let session = LingShuAgentSession(
            id: "accept-\(UUID().uuidString.prefix(6))",
            system: LingShuAcceptancePlanner.systemPrompt,
            tools: [], model: controlPlaneModelAdapter(.acceptancePlanner), maxTurns: 1
        )
        let payload = "成功标准:\n" + cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        guard case .completed(let text) = await session.send(payload) else { return fallback }
        return LingShuAcceptancePlanner.parse(LingShuReasoningText.stripThinkTags(text), fallbackCriteria: cleaned)
    }

    /// 缓存分类后的检查项到记录(typed,持久化)。
    func bindAcceptanceChecks(_ checks: [LingShuAcceptanceCheck], to recordID: String?) {
        guard let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[idx].acceptanceChecks = checks
        persistTaskExecutionRecords()
    }

    func acceptanceChecks(for recordID: String?) -> [LingShuAcceptanceCheck]? {
        guard let recordID else { return nil }
        return taskExecutionRecords.first(where: { $0.id == recordID })?.acceptanceChecks
    }

    /// P3 验收触发条件:只有 task 型目标且带成功标准才强制跑 GoalSpec 验收。
    /// 闲聊/问答不因 GoalSpec 误判而加重模型调用;但 task 即便没产物也要跑,让缺文件/缺命令能被硬门发现。
    func shouldRunGoalAcceptance(taskRecordID: String?) -> Bool {
        guard goalSpecEnabled, let spec = goalSpec(for: taskRecordID) else { return false }
        return spec.kind == .task && !spec.successCriteria.isEmpty
    }

    /// 把验收报告绑定到记录(typed,持久化)+ 落 trace,供用户验收逐条核对。
    func bindAcceptanceReport(_ report: LingShuAcceptanceReport, to recordID: String?) {
        guard !report.isEmpty, let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[idx].acceptanceReport = report
        persistTaskExecutionRecords()
    }

    /// fileExists 探针:只认**本任务证据集**里的真实文件(登记产出物 ∪ 本次回复声明且盘上存在的文件)。
    /// 不直接扫描工作目录,避免历史旧文件把本轮未产出的成功标准误判为达成。
    func acceptanceFileExists(_ probe: String, realFiles: [String]) -> Bool {
        let trimmed = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalizedRealFiles = Set(realFiles.map { ($0 as NSString).standardizingPath })
        let base = (trimmed as NSString).lastPathComponent.lowercased()
        if base.hasPrefix("*.") {
            let ext = String(base.dropFirst(2))
            return normalizedRealFiles.contains { ($0 as NSString).pathExtension.lowercased() == ext }
        }
        let abs = trimmed.hasPrefix("/") ? trimmed : (codexWorkingDirectory as NSString).appendingPathComponent(trimmed)
        let normalizedProbe = (abs as NSString).standardizingPath
        if normalizedRealFiles.contains(normalizedProbe) { return true }
        return normalizedRealFiles.contains { ($0 as NSString).lastPathComponent.lowercased() == base }
    }

    /// commandSucceeds 探针:扫执行记录里 run_command 配对,看含探针子串的命令是否成功执行过。
    /// 出现且成功(退出成功且输出无崩溃签名)=true;出现但失败=false;从未出现=nil(无法确定性核验)。
    /// 一次成功即判达成(返工里"先失败后修绿"算达成)。
    func commandProbeOutcome(_ probe: String, taskRecordID: String?) -> Bool? {
        guard let record = taskExecutionRecords.first(where: { $0.id == taskRecordID }) else { return nil }
        let needle = probe.lowercased()
        guard !needle.isEmpty else { return nil }
        var lastCmd = ""
        var outcome: Bool? = nil
        for message in record.messages {
            switch message.detail {
            case let .toolCall(tool, summary, args):
                if tool == "run_command" { lastCmd = (summary + " " + args).lowercased() }
            case let .toolResult(tool, success, output):
                if tool == "run_command", lastCmd.contains(needle) {
                    let ok = success && !Self.outputLooksLikeCrash(output)
                    if ok { outcome = true } else if outcome != true { outcome = false }
                }
                lastCmd = ""
            default:
                break
            }
        }
        return outcome
    }
}
