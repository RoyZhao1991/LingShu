import XCTest
@testable import LingShuMac

/// 200+ 条确定性端到端验收:
/// 用户目标 -> 任务记录 -> GoalSpec -> 能力需求/图谱 -> GapAnalysis -> 产出物/命令证据
/// -> P3 成功标准验收 -> 真实效果验收 -> 终态/经验沉淀/世界模型。
///
/// 这里不调用真模型,保证可重复;测的是灵枢中枢框架本身是否把 1 条真实目标完整流转起来。
final class FullStackE2E200Tests: XCTestCase {
    private struct Scenario {
        enum Kind { case deliverable, blockedExternal, question, revision }
        let index: Int
        let kind: Kind
        let prompt: String
        let objective: String
        let fileName: String?
        let command: String?
        let requirements: [LingShuCapabilityRequirement]
    }

    @MainActor
    func testGeneralHubFullStackE2E_220Cases() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-e2e-220-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let defaults = UserDefaults.standard
        let experienceBackup = defaults.data(forKey: "lingshu.goal.experiences")
        let acquiredBackup = defaults.data(forKey: "lingshu.capability.acquired")
        defaults.removeObject(forKey: "lingshu.goal.experiences")
        defaults.removeObject(forKey: "lingshu.capability.acquired")
        defer {
            if let experienceBackup {
                defaults.set(experienceBackup, forKey: "lingshu.goal.experiences")
            } else {
                defaults.removeObject(forKey: "lingshu.goal.experiences")
            }
            if let acquiredBackup {
                defaults.set(acquiredBackup, forKey: "lingshu.capability.acquired")
            } else {
                defaults.removeObject(forKey: "lingshu.capability.acquired")
            }
        }

        let state = LingShuState()
        state.agentWorkingDirectory = tempRoot.path
        let scenarios = Self.makeScenarios()
        XCTAssertGreaterThanOrEqual(scenarios.count, 200)

        var createdRecordIDs: [String] = []
        var passCount = 0
        defer {
            state.taskExecutionRecords.removeAll { createdRecordIDs.contains($0.id) }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        for scenario in scenarios {
            let recordID = state.createTaskExecutionRecord(for: scenario.prompt)
            createdRecordIDs.append(recordID)

            let spec = makeGoalSpec(for: scenario)
            state.bindGoalSpec(spec, to: recordID)
            state.bindCapabilityRequirements(scenario.requirements, to: recordID)
            state.bindGapAnalysis(makeGapAnalysis(for: scenario), to: recordID)
            let guidance = state.assembledExecutionGuidance(base: "基础执行策略", taskRecordID: recordID)
            XCTAssertTrue(guidance.contains(scenario.objective), "case \(scenario.index): 前置引导必须包含目标")

            switch scenario.kind {
            case .deliverable:
                try await runDeliverableScenario(scenario, recordID: recordID, tempRoot: tempRoot, state: state)
            case .blockedExternal:
                await runBlockedScenario(scenario, recordID: recordID, state: state)
            case .question:
                await runQuestionScenario(scenario, recordID: recordID, state: state)
            case .revision:
                await runRevisionScenario(scenario, recordID: recordID, tempRoot: tempRoot, state: state)
            }

            let final = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == recordID }, "case \(scenario.index): 记录必须存在")
            XCTAssertNotNil(final.goalSpec, "case \(scenario.index): GoalSpec 必须落 typed 字段")
            XCTAssertNotNil(final.gapAnalysis, "case \(scenario.index): GapAnalysis 必须落 typed 字段")
            XCTAssertFalse(final.capabilityRequirements?.isEmpty ?? true, "case \(scenario.index): 能力需求必须落 typed 字段")
            XCTAssertNotNil(state.worldModel.tasks.first { $0.id == recordID }, "case \(scenario.index): 世界模型必须有任务态")

            passCount += 1
        }

        XCTAssertEqual(passCount, scenarios.count)
        XCTAssertGreaterThanOrEqual(state.goalExperiences().count, 1, "终态任务应沉淀可复用经验")
    }

    @MainActor
    private func runDeliverableScenario(
        _ scenario: Scenario,
        recordID: String,
        tempRoot: URL,
        state: LingShuState
    ) async throws {
        let fileName = try XCTUnwrap(scenario.fileName)
        let file = tempRoot.appendingPathComponent(fileName)
        try "E2E deliverable \(scenario.index)\n".write(to: file, atomically: true, encoding: .utf8)
        state.appendTaskRecordArtifact(recordID, title: fileName, location: file.path, producer: "E2E执行器", operation: .created)
        if let command = scenario.command {
            appendRunCommand(command, success: true, recordID: recordID, state: state)
        }

        let checks = acceptanceChecks(for: scenario)
        state.bindAcceptanceChecks(checks, to: recordID)
        let report = await state.acceptanceReport(taskRecordID: recordID, realFiles: [file.path])
        state.bindAcceptanceReport(report, to: recordID)
        let effect = state.effectVerificationReport(from: report)
        state.bindEffectVerificationReport(effect, to: recordID)
        state.finishTaskRecord(recordID, status: .verified, summary: "E2E case \(scenario.index) verified")

        XCTAssertFalse(report.hasDeterministicFailure, "case \(scenario.index): 成功交付不应触发确定性失败")
        XCTAssertTrue(report.deterministicallyMet.contains { $0.kind == .fileExists }, "case \(scenario.index): 文件存在必须被核验")
        XCTAssertFalse(effect.hasFailure, "case \(scenario.index): 真实效果验收不应失败")
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == recordID }?.status, .verified)
    }

    @MainActor
    private func runBlockedScenario(_ scenario: Scenario, recordID: String, state: LingShuState) async {
        state.finishTaskRecord(recordID, status: .waitingForUser, summary: "等待用户授权或提供外部系统凭据")
        let gap = state.gapAnalysis(for: recordID)
        XCTAssertTrue(gap?.blockingNeedsUser == true, "case \(scenario.index): 外部阻断必须识别为需要用户参与")
        XCTAssertTrue(gap?.needsUserToUnblock == true, "case \(scenario.index): 必须指示先问用户拿前提")
        let graph = state.capabilityGraph()
        if case .missing = graph.match(.init(verb: .externalSystemWrite, target: "外部系统", detail: "写入")) {
            // 没有授权/适配器时允许是 missing;CompletionGate 会据 gap 拦截。
        } else if case .needsAuth = graph.match(.init(verb: .externalSystemWrite, target: "外部系统", detail: "写入")) {
            // 探测器已经发现但待授权也正确。
        } else {
            XCTFail("case \(scenario.index): 未授权外部写入不能被判 satisfied")
        }
    }

    @MainActor
    private func runQuestionScenario(_ scenario: Scenario, recordID: String, state: LingShuState) async {
        state.appendTaskRecordMessage(recordID, actor: "灵枢", role: "回答", kind: .result, text: "这是一个直接回答。")
        let report = await state.acceptanceReport(taskRecordID: recordID, realFiles: [])
        state.finishTaskRecord(recordID, status: .answered, summary: "已直接回答")
        XCTAssertTrue(report.isEmpty, "case \(scenario.index): 普通问答不应触发重型成功标准验收")
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == recordID }?.status, .answered)
    }

    @MainActor
    private func runRevisionScenario(
        _ scenario: Scenario,
        recordID: String,
        tempRoot: URL,
        state: LingShuState
    ) async {
        if let command = scenario.command {
            appendRunCommand(command, success: false, recordID: recordID, state: state)
        }
        state.bindAcceptanceChecks(acceptanceChecks(for: scenario), to: recordID)
        let report = await state.acceptanceReport(taskRecordID: recordID, realFiles: [])
        state.bindAcceptanceReport(report, to: recordID)
        let effect = state.effectVerificationReport(from: report)
        state.bindEffectVerificationReport(effect, to: recordID)
        state.finishTaskRecord(recordID, status: .needsRevision, summary: report.deterministicFailureReason)

        XCTAssertTrue(report.hasDeterministicFailure, "case \(scenario.index): 缺文件/命令失败必须被硬门打回")
        XCTAssertTrue(effect.hasFailure, "case \(scenario.index): 真实效果验收应沉淀失败证据")
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == recordID }?.status, .needsRevision)
    }

    @MainActor
    private func appendRunCommand(_ command: String, success: Bool, recordID: String, state: LingShuState) {
        state.appendTaskRecordMessage(
            recordID,
            actor: "执行器",
            role: "命令",
            kind: .agent,
            text: "执行 \(command)",
            detail: .toolCall(tool: "run_command", summary: command, arguments: #"{"cmd":"\#(command)"}"#)
        )
        state.appendTaskRecordMessage(
            recordID,
            actor: "执行器",
            role: "结果",
            kind: success ? .result : .warning,
            text: success ? "命令成功" : "命令失败",
            detail: .toolResult(tool: "run_command", success: success, output: success ? "0 passed" : "1 failed")
        )
    }

    private func makeGoalSpec(for scenario: Scenario) -> LingShuGoalSpec {
        switch scenario.kind {
        case .deliverable:
            var criteria = ["生成 \(scenario.fileName ?? "产出文件")"]
            if let command = scenario.command { criteria.append("\(command) 全绿") }
            return .init(objective: scenario.objective, kind: .task,
                         constraints: ["本地完成", "产出可验收"],
                         boundaries: ["不伪造完成结果"],
                         risks: [],
                         successCriteria: criteria)
        case .blockedExternal:
            return .init(objective: scenario.objective, kind: .task,
                         constraints: ["需要写入外部系统"],
                         boundaries: ["没有授权不得假装已写入"],
                         risks: ["外部账号授权"],
                         successCriteria: ["外部系统写入成功"],
                         openQuestions: ["请提供外部系统授权或接入方式"])
        case .question:
            return .init(objective: scenario.objective, kind: .question,
                         constraints: ["直接回答"], successCriteria: ["回答清楚"])
        case .revision:
            var criteria = ["生成 \(scenario.fileName ?? "缺失文件")"]
            if let command = scenario.command { criteria.append("\(command) 全绿") }
            return .init(objective: scenario.objective, kind: .task,
                         constraints: ["必须真实产出"],
                         boundaries: ["文件不存在不得交付"],
                         successCriteria: criteria)
        }
    }

    private func makeGapAnalysis(for scenario: Scenario) -> LingShuGapAnalysis {
        switch scenario.kind {
        case .blockedExternal:
            return .init(feasibleNow: false, gaps: [
                .init(kind: .permission, missing: "外部系统账号授权", fillPath: "先向用户确认授权或接入方式", blocking: true)
            ], note: "没有授权不得写入外部系统。")
        default:
            return .init(feasibleNow: true, gaps: [], note: "现有能力足以推进。")
        }
    }

    private func acceptanceChecks(for scenario: Scenario) -> [LingShuAcceptanceCheck] {
        switch scenario.kind {
        case .deliverable, .revision:
            var checks = [
                LingShuAcceptanceCheck(kind: .fileExists,
                                       criterion: "生成 \(scenario.fileName ?? "产出文件")",
                                       probe: scenario.fileName)
            ]
            if let command = scenario.command {
                checks.append(.init(kind: .commandSucceeds, criterion: "\(command) 全绿", probe: command))
            }
            return checks
        case .blockedExternal:
            return [.init(kind: .userConfirmation, criterion: "用户授权后再写入外部系统", probe: nil)]
        case .question:
            return []
        }
    }

    private static func makeScenarios() -> [Scenario] {
        var cases: [Scenario] = []

        for i in 0..<120 {
            let ext = ["pdf", "pptx", "png", "wav", "mp4"][i % 5]
            let command = i % 3 == 0 ? "swift test" : (i % 3 == 1 ? "pytest" : nil)
            cases.append(.init(
                index: cases.count,
                kind: .deliverable,
                prompt: "帮我本地生成第 \(i) 份工程产出并验收",
                objective: "生成第 \(i) 份工程产出",
                fileName: "deliverable-\(i).\(ext)",
                command: command,
                requirements: [
                    .init(verb: .documentGenerate, target: "本地产出", detail: "生成文件"),
                    .init(verb: .localFileScan, target: "工作目录", detail: "核验产出"),
                    .init(verb: .compute, target: "本地计算", detail: "必要的数据处理")
                ]
            ))
        }

        for i in 0..<40 {
            cases.append(.init(
                index: cases.count,
                kind: .blockedExternal,
                prompt: "把第 \(i) 批结果同步到外部系统",
                objective: "同步第 \(i) 批结果到外部系统",
                fileName: nil,
                command: nil,
                requirements: [
                    .init(verb: .externalSystemWrite, target: "外部系统", detail: "写入数据"),
                    .init(verb: .humanConfirm, target: "账号授权", detail: "需要用户授权")
                ]
            ))
        }

        for i in 0..<30 {
            cases.append(.init(
                index: cases.count,
                kind: .question,
                prompt: "第 \(i) 个普通问答:解释一下灵枢的中枢定位",
                objective: "回答第 \(i) 个普通问题",
                fileName: nil,
                command: nil,
                requirements: [.init(verb: .compute, target: "对话", detail: "直接回答")]
            ))
        }

        for i in 0..<30 {
            let command = i % 2 == 0 ? "swift test" : nil
            cases.append(.init(
                index: cases.count,
                kind: .revision,
                prompt: "第 \(i) 个失败验收:声称生成文件但实际上没有",
                objective: "核验第 \(i) 个失败交付",
                fileName: "missing-\(i).md",
                command: command,
                requirements: [
                    .init(verb: .documentGenerate, target: "本地产出", detail: "生成文件"),
                    .init(verb: .localFileScan, target: "工作目录", detail: "核验产出")
                ]
            ))
        }

        return cases
    }
}
