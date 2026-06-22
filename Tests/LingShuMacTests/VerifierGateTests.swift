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
}
