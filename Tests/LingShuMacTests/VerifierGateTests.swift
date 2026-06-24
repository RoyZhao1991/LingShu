import XCTest
@testable import LingShuMac

/// 差距2·薄基线:按交付物类型 gate 贵 LLM 评审的纯逻辑守卫。
/// 核心断言:**代码且确定性门绿 → 跳过 LLM**;主观交付物 → 跑 LLM;确定性门**永不跳过**(本测只 gate LLM)。
final class VerifierGateTests: XCTestCase {

    func testPureCodeGateGreenSkipsLLM() {
        let d = LingShuVerifierGate.decide(codeFileCount: 2, hasSubjectiveArtifact: false, codeGatePassed: true)
        XCTAssertEqual(d, .skipPassedByDeterministicGate, "纯代码 + 确定性门绿 → 应跳过 LLM 直接通过")
    }

    func testPureCodeGateRedSkipsLLMButFails() {
        let d = LingShuVerifierGate.decide(codeFileCount: 1, hasSubjectiveArtifact: false, codeGatePassed: false)
        XCTAssertEqual(d, .skipFailedByDeterministicGate, "纯代码 + 确定性门红 → 跳过 LLM 但按确定性失败返工")
    }

    func testSubjectiveDeliverableRunsLLM() {
        // 主观交付物(无可测代码)→ 必须跑 LLM(确定性门管不到事实/版式)。
        let d = LingShuVerifierGate.decide(codeFileCount: 0, hasSubjectiveArtifact: true, codeGatePassed: true)
        XCTAssertEqual(d, .runLLMReview)
    }

    func testMixedCodeAndSubjectiveRunsLLM() {
        // 代码 + PPT 混合:PPT 需主观评审 → 跑 LLM(LLM 内仍硬enforce代码门)。
        let d = LingShuVerifierGate.decide(codeFileCount: 2, hasSubjectiveArtifact: true, codeGatePassed: true)
        XCTAssertEqual(d, .runLLMReview, "混合交付应跑 LLM(主观部分需评审)")
    }

    func testNoArtifactRunsLLM() {
        // 既无代码也无主观文件(纯回复声称)→ 走 LLM 路径(保守)。
        let d = LingShuVerifierGate.decide(codeFileCount: 0, hasSubjectiveArtifact: false, codeGatePassed: true)
        XCTAssertEqual(d, .runLLMReview)
    }

    func testCommandOnlyAcceptanceCanSkipLLM() {
        let report = LingShuAcceptanceReport(verdicts: [
            .init(criterion: "成功调用 recall_local", kind: .commandSucceeds, status: .met, evidence: "toolResult success"),
            .init(criterion: "成功调用 index_calendar", kind: .commandSucceeds, status: .met, evidence: "toolResult success")
        ], note: "")

        XCTAssertTrue(LingShuVerifierGate.deterministicAcceptanceCanSkipLLM(report),
                      "纯工具/命令型成功标准已由执行记录证明时,不应再进入 LLM 主观审查死循环")
    }

    func testFileOrSubjectiveAcceptanceStillRunsLLM() {
        let fileReport = LingShuAcceptanceReport(verdicts: [
            .init(criterion: "生成 report.md", kind: .fileExists, status: .met, evidence: "文件存在")
        ], note: "")
        let subjectiveReport = LingShuAcceptanceReport(verdicts: [
            .init(criterion: "内容覆盖三大主题", kind: .contentQuality, status: .unverifiable, evidence: "交评审官")
        ], note: "")
        let failedReport = LingShuAcceptanceReport(verdicts: [
            .init(criterion: "成功调用 recall_local", kind: .commandSucceeds, status: .unmet, evidence: "执行失败")
        ], note: "")

        XCTAssertFalse(LingShuVerifierGate.deterministicAcceptanceCanSkipLLM(fileReport),
                       "文件存在只能说明落盘,不能替代内容/版式评审")
        XCTAssertFalse(LingShuVerifierGate.deterministicAcceptanceCanSkipLLM(subjectiveReport),
                       "内容质量仍需主观评审")
        XCTAssertFalse(LingShuVerifierGate.deterministicAcceptanceCanSkipLLM(failedReport),
                       "确定性未达成不能短路")
    }

    // MARK: 代码确定性门校准(能力加固:测试绿 或 真构建/运行通过,二者择一)

    func testFullChainPasses() {
        // 测试全绿 + 跑出可见结果 + 没崩 → 通过。
        XCTAssertTrue(LingShuVerifierGate.codeDeterministicGatePasses(hasCodeFiles: true, testsGreen: true, ranWithVisibleOutput: true, runCrashed: false))
    }

    func testBuildOnlyNoTestsFails() {
        // 用户校准:**构建≠成功**。没跑测试,即使有可见输出也不达标。
        XCTAssertFalse(LingShuVerifierGate.codeDeterministicGatePasses(hasCodeFiles: true, testsGreen: false, ranWithVisibleOutput: true, runCrashed: false))
    }

    func testTestsGreenButNoVisibleResultFails() {
        // 测绿但没看到真实运行结果(只编译/空跑「无输出退出码0」)→ 不达标(我要看到结果)。
        XCTAssertFalse(LingShuVerifierGate.codeDeterministicGatePasses(hasCodeFiles: true, testsGreen: true, ranWithVisibleOutput: false, runCrashed: false))
    }

    func testRunCrashedFails() {
        // 跑崩了是硬错。
        XCTAssertFalse(LingShuVerifierGate.codeDeterministicGatePasses(hasCodeFiles: true, testsGreen: true, ranWithVisibleOutput: true, runCrashed: true))
    }

    func testNonCodeAlwaysPasses() {
        XCTAssertTrue(LingShuVerifierGate.codeDeterministicGatePasses(hasCodeFiles: false, testsGreen: false, ranWithVisibleOutput: false, runCrashed: false))
    }

    func testSubjectiveExtensionDetection() {
        XCTAssertTrue(LingShuVerifierGate.hasSubjectiveArtifact(realFilePaths: ["/x/a.py", "/x/deck.pptx"]))
        XCTAssertTrue(LingShuVerifierGate.hasSubjectiveArtifact(realFilePaths: ["/x/report.md"]))
        XCTAssertFalse(LingShuVerifierGate.hasSubjectiveArtifact(realFilePaths: ["/x/a.py", "/x/test_a.py"]))
        XCTAssertFalse(LingShuVerifierGate.hasSubjectiveArtifact(realFilePaths: []))
    }

    func testInvalidReviewerProtocolTextIsNonActionable() {
        XCTAssertTrue(LingShuVerifierGate.isNonActionableReviewCritique(
            "⚠️ 需修正 — 评审器未返回有效意见，且缺少可核验的确定性证据。"
        ))
        XCTAssertTrue(LingShuVerifierGate.isNonActionableReviewCritique(""))
    }

    func testConcreteReviewCritiqueIsActionable() {
        let critique = """
        1. 真实性:达标
        2. 完整性:未达标,缺少目标网站字段说明
        核对统计 PASS=1 FAIL=1
        结论:需修正
        """
        XCTAssertFalse(LingShuVerifierGate.isNonActionableReviewCritique(critique))
    }

    func testHostEvidenceCanReplaceInvalidReviewOnlyWhenRealEvidenceExists() {
        let emptyReport = LingShuAcceptanceReport(verdicts: [], note: "")
        XCTAssertTrue(LingShuVerifierGate.hostDeterministicEvidenceCanReplaceInvalidReview(
            codeEvidenceClean: true,
            realFiles: ["/tmp/report.md"],
            hadAction: false,
            acceptance: emptyReport
        ))
        XCTAssertFalse(LingShuVerifierGate.hostDeterministicEvidenceCanReplaceInvalidReview(
            codeEvidenceClean: true,
            realFiles: [],
            hadAction: false,
            acceptance: emptyReport
        ), "纯口头声称不能因为评审失效而放行")

        let failedReport = LingShuAcceptanceReport(verdicts: [
            .init(criterion: "生成 a.pdf", kind: .fileExists, status: .unmet, evidence: "文件不存在")
        ], note: "")
        XCTAssertFalse(LingShuVerifierGate.hostDeterministicEvidenceCanReplaceInvalidReview(
            codeEvidenceClean: true,
            realFiles: ["/tmp/other.md"],
            hadAction: false,
            acceptance: failedReport
        ), "成功标准确定性失败时不能被无效评审兜底覆盖")
    }
}
