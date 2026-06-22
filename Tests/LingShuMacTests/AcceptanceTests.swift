import XCTest
@testable import LingShuMac

/// 通用中枢 P3·全类型验收:分类解析容错 + 确定性裁决合并 + 硬门/注入(纯逻辑,无模型)。
final class AcceptanceTests: XCTestCase {

    // MARK: 分类解析

    func testParseTypedChecks() {
        let raw = """
        ```json
        [
          {"criterion":"生成 report.pdf","kind":"file_exists","probe":"report.pdf"},
          {"criterion":"测试全绿","kind":"command_succeeds","probe":"swift test"},
          {"criterion":"床头灯亮起","kind":"device_effect","probe":""},
          {"criterion":"内容覆盖三大主题","kind":"content_quality","probe":""}
        ]
        ```
        """
        let checks = LingShuAcceptancePlanner.parse(raw, fallbackCriteria: [])
        XCTAssertEqual(checks.count, 4)
        XCTAssertEqual(checks[0].kind, .fileExists)
        XCTAssertEqual(checks[0].probe, "report.pdf")
        XCTAssertEqual(checks[1].kind, .commandSucceeds)
        XCTAssertEqual(checks[2].kind, .deviceEffect)
        XCTAssertNil(checks[2].probe, "空 probe → nil")
        XCTAssertEqual(checks[3].kind, .contentQuality)
    }

    func testParseFallsBackToContentQualityWhenGarbage() {
        let checks = LingShuAcceptancePlanner.parse("这根本不是 JSON", fallbackCriteria: ["标准A", "标准B"])
        XCTAssertEqual(checks.count, 2, "解析失败 → 回退,不丢条目")
        XCTAssertTrue(checks.allSatisfy { $0.kind == .contentQuality }, "回退全交评审官")
        XCTAssertEqual(checks.first?.criterion, "标准A")
    }

    func testParseNeverDropsMissingCriteriaWhenPlannerReturnsPartialArray() {
        let raw = """
        [
          {"criterion":"生成 report.pdf","kind":"file_exists","probe":"report.pdf"},
          {"criterion":"测试全绿","kind":"command_succeeds","probe":"swift test"}
        ]
        """
        let checks = LingShuAcceptancePlanner.parse(
            raw,
            fallbackCriteria: ["生成 report.pdf", "内容覆盖三大主题", "测试全绿"]
        )
        XCTAssertEqual(checks.count, 3, "模型少返验收项时也必须与原成功标准一一对应")
        XCTAssertEqual(checks[0].kind, .fileExists)
        XCTAssertEqual(checks[1].kind, .contentQuality, "漏掉的中间项回退交评审官,不能静默消失")
        XCTAssertEqual(checks[1].criterion, "内容覆盖三大主题")
        XCTAssertEqual(checks[2].kind, .commandSucceeds)
    }

    func testParseUsesOriginalCriteriaWhenPlannerRewordsSameCount() {
        let raw = """
        [
          {"criterion":"需要生成PDF报告","kind":"file_exists","probe":"report.pdf"}
        ]
        """
        let checks = LingShuAcceptancePlanner.parse(raw, fallbackCriteria: ["生成 report.pdf"])
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks[0].criterion, "生成 report.pdf", "验收报告必须回指 GoalSpec 原成功标准")
        XCTAssertEqual(checks[0].kind, .fileExists)
    }

    func testParseKindToleratesAliases() {
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("fileExists"), .fileExists)
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("command"), .commandSucceeds)
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("test"), .commandSucceeds)
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("env"), .environmentChange)
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("瞎写"), .contentQuality, "未知 kind 兜底交评审官")
    }

    func testIsDeterministic() {
        XCTAssertTrue(LingShuCriterionKind.fileExists.isDeterministic)
        XCTAssertTrue(LingShuCriterionKind.commandSucceeds.isDeterministic)
        XCTAssertFalse(LingShuCriterionKind.deviceEffect.isDeterministic)
        XCTAssertFalse(LingShuCriterionKind.userConfirmation.isDeterministic)
        XCTAssertFalse(LingShuCriterionKind.contentQuality.isDeterministic)
    }

    // MARK: 确定性裁决合并(核心)

    func testEvaluateFileExistsMetAndUnmet() {
        let checks = [
            LingShuAcceptanceCheck(kind: .fileExists, criterion: "有 a.pdf", probe: "a.pdf"),
            LingShuAcceptanceCheck(kind: .fileExists, criterion: "有 missing.pptx", probe: "missing.pptx")
        ]
        let report = LingShuAcceptanceReport.make(
            checks: checks,
            fileExists: { $0 == "a.pdf" },
            commandSucceeded: { _ in nil }
        )
        XCTAssertEqual(report.verdicts[0].status, .met)
        XCTAssertEqual(report.verdicts[1].status, .unmet)
        XCTAssertTrue(report.hasDeterministicFailure, "有文件缺失 → 硬门触发")
        XCTAssertEqual(report.deterministicFailures.count, 1)
    }

    func testEvaluateFileExistsNoProbeIsUnverifiable() {
        let report = LingShuAcceptanceReport.make(
            checks: [LingShuAcceptanceCheck(kind: .fileExists, criterion: "有产出", probe: nil)],
            fileExists: { _ in false },
            commandSucceeded: { _ in nil }
        )
        XCTAssertEqual(report.verdicts[0].status, .unverifiable, "无探针不能判 unmet,避免误返工")
        XCTAssertFalse(report.hasDeterministicFailure)
    }

    func testEvaluateCommandSucceedsTriState() {
        let checks = [
            LingShuAcceptanceCheck(kind: .commandSucceeds, criterion: "测试绿", probe: "swift test"),
            LingShuAcceptanceCheck(kind: .commandSucceeds, criterion: "构建过", probe: "make build"),
            LingShuAcceptanceCheck(kind: .commandSucceeds, criterion: "压测过", probe: "bench")
        ]
        let report = LingShuAcceptanceReport.make(
            checks: checks,
            fileExists: { _ in false },
            commandSucceeded: { probe in
                switch probe {
                case "swift test": return true
                case "make build": return false
                default: return nil
                }
            }
        )
        XCTAssertEqual(report.verdicts[0].status, .met)
        XCTAssertEqual(report.verdicts[1].status, .unmet, "命令出现但失败 → unmet")
        XCTAssertEqual(report.verdicts[2].status, .unverifiable, "命令从未出现 → 无法核验")
        XCTAssertTrue(report.hasDeterministicFailure)
    }

    func testEvaluateNonDeterministicKindsAreUnverifiableNeverHallucinatedMet() {
        let checks = [
            LingShuAcceptanceCheck(kind: .deviceEffect, criterion: "开灯", probe: nil),
            LingShuAcceptanceCheck(kind: .environmentChange, criterion: "服务起来", probe: nil),
            LingShuAcceptanceCheck(kind: .userConfirmation, criterion: "用户满意", probe: nil),
            LingShuAcceptanceCheck(kind: .contentQuality, criterion: "写得好", probe: nil)
        ]
        let report = LingShuAcceptanceReport.make(checks: checks, fileExists: { _ in true }, commandSucceeded: { _ in true })
        XCTAssertTrue(report.verdicts.allSatisfy { $0.status == .unverifiable }, "非确定性类型一律 unverifiable,绝不幻觉为达成")
        XCTAssertFalse(report.hasDeterministicFailure, "unverifiable 不触发硬门")
        XCTAssertEqual(report.unverifiable.count, 4)
    }

    @MainActor
    func testFileExistsUsesTaskEvidenceNotStaleWorkspaceFile() throws {
        let state = LingShuState()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-p3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("report.pdf").path
        FileManager.default.createFile(atPath: stale, contents: Data("old".utf8))
        state.codexWorkingDirectory = dir.path

        XCTAssertFalse(state.acceptanceFileExists("report.pdf", realFiles: []),
                       "工作目录里有旧文件但本任务没有登记/声明时,不能算本轮达成")
        XCTAssertTrue(state.acceptanceFileExists("report.pdf", realFiles: [stale]),
                      "本任务证据集包含该文件时才算达成")
        XCTAssertTrue(state.acceptanceFileExists("*.pdf", realFiles: [stale]))
    }

    @MainActor
    func testGoalAcceptanceTriggersOnlyForTaskCriteria() {
        let state = LingShuState()
        let taskID = state.createTaskExecutionRecord(for: "生成报告")
        state.bindGoalSpec(LingShuGoalSpec(objective: "生成报告", kind: .task, successCriteria: ["生成 report.pdf"]), to: taskID)
        XCTAssertTrue(state.shouldRunGoalAcceptance(taskRecordID: taskID))

        let questionID = state.createTaskExecutionRecord(for: "解释一个概念")
        state.bindGoalSpec(LingShuGoalSpec(objective: "解释概念", kind: .question, successCriteria: ["回答清楚"]), to: questionID)
        XCTAssertFalse(state.shouldRunGoalAcceptance(taskRecordID: questionID), "问答不应因成功标准误触发重型交付验收")

        let noCriteriaID = state.createTaskExecutionRecord(for: "做点事")
        state.bindGoalSpec(LingShuGoalSpec(objective: "做点事", kind: .task), to: noCriteriaID)
        XCTAssertFalse(state.shouldRunGoalAcceptance(taskRecordID: noCriteriaID))
    }

    func testVerifierBlockAndFailureReason() {
        let report = LingShuAcceptanceReport.make(
            checks: [
                LingShuAcceptanceCheck(kind: .fileExists, criterion: "有 a.pdf", probe: "a.pdf"),
                LingShuAcceptanceCheck(kind: .fileExists, criterion: "有 b.pdf", probe: "b.pdf"),
                LingShuAcceptanceCheck(kind: .contentQuality, criterion: "内容完整", probe: nil)
            ],
            fileExists: { $0 == "a.pdf" },
            commandSucceeded: { _ in nil }
        )
        let block = report.verifierBlock
        XCTAssertTrue(block.contains("✅达成"))
        XCTAssertTrue(block.contains("❌未达成"))
        XCTAssertTrue(block.contains("◽待判"))
        XCTAssertTrue(block.contains("不要假定已达成"))
        XCTAssertTrue(report.deterministicFailureReason.contains("b.pdf"), "返工指引点名缺失项")
    }

    func testEmptyReportInjectsNothing() {
        let report = LingShuAcceptanceReport(verdicts: [], note: "")
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.verifierBlock, "", "无成功标准 → 不给评审官加压")
        XCTAssertFalse(report.hasDeterministicFailure)
    }

    // MARK: 持久化

    func testRecordPersistsTypedAcceptance() throws {
        var rec = LingShuTaskExecutionRecord.create(prompt: "做 PPT")
        rec.acceptanceChecks = [LingShuAcceptanceCheck(kind: .fileExists, criterion: "有 ppt", probe: "*.pptx")]
        rec.acceptanceReport = LingShuAcceptanceReport(verdicts: [
            LingShuCheckVerdict(criterion: "有 ppt", kind: .fileExists, status: .met, evidence: "盘上有")
        ], note: "")
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: data)
        XCTAssertEqual(back.acceptanceChecks?.first?.probe, "*.pptx", "检查项随记录跨重启")
        XCTAssertEqual(back.acceptanceReport?.verdicts.first?.status, .met, "验收报告随记录跨重启")
    }

    func testOldRecordWithoutAcceptanceDecodesNil() throws {
        let json = #"{"id":"r1","title":"t","prompt":"p","status":"已完成","summary":"s","participants":["你"],"createdAt":0,"updatedAt":0,"messages":[]}"#
        let rec = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: Data(json.utf8))
        XCTAssertNil(rec.acceptanceChecks, "老记录无字段 → nil 向后兼容")
        XCTAssertNil(rec.acceptanceReport)
    }
}
