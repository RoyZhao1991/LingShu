import XCTest
@testable import LingShuMac

/// # 真实结果后置校验(verifyOutcome)+ 升级阶梯并入验收门 测试 —— 方案 §2/§6
///
/// 守住:① 动作工具识别 ② "写文档冒充"高危信号(唯一交付是文档+无真实动作)③ 验收返工引导逐级加厚。
final class OutcomeVerificationTests: XCTestCase {

    // MARK: - ① 动作工具识别(非产出/读取/元工具 = 真实动作)

    func testActionToolClassification() {
        // 产出/读取/元工具:不算真实动作
        XCTAssertFalse(LingShuOutcomeVerification.isActionTool("write_file"))
        XCTAssertFalse(LingShuOutcomeVerification.isActionTool("run_command"))
        XCTAssertFalse(LingShuOutcomeVerification.isActionTool("web_search"))
        XCTAssertFalse(LingShuOutcomeVerification.isActionTool("author_component"))
        // 作用于真实世界/设备/界面:真实动作(自编执行器工具、计算机操作)
        XCTAssertTrue(LingShuOutcomeVerification.isActionTool("set_bedside_light"), "自编执行器工具=动作")
        XCTAssertTrue(LingShuOutcomeVerification.isActionTool("click"))
        XCTAssertTrue(LingShuOutcomeVerification.isActionTool("type_text"))
        XCTAssertTrue(LingShuOutcomeVerification.isActionTool("peripheral_control"))
    }

    // MARK: - ② 写文档冒充信号

    func testDocImpersonationFiresWhenOnlyDocsAndNoAction() {
        // 唯一交付是一篇 .md 指南、没有任何真实动作成功 → 高危(根治"写文档冒充接入")
        XCTAssertTrue(LingShuOutcomeVerification.isDocumentImpersonationSignal(
            artifactExtensions: ["md"], hadActionToolSuccess: false))
        XCTAssertTrue(LingShuOutcomeVerification.isDocumentImpersonationSignal(
            artifactExtensions: ["/Users/x/接入指南.md", "/Users/x/说明.txt"], hadActionToolSuccess: false),
            "全路径也按扩展名判,全是文档→报警")
    }

    func testDocImpersonationSilentWhenRealAction() {
        // 有真实动作执行成功 → 不是冒充(真做到了)
        XCTAssertFalse(LingShuOutcomeVerification.isDocumentImpersonationSignal(
            artifactExtensions: ["md"], hadActionToolSuccess: true))
    }

    func testDocImpersonationSilentWhenNoArtifactsOrHasCode() {
        // 没有任何产出物(纯动作任务) → 不触发
        XCTAssertFalse(LingShuOutcomeVerification.isDocumentImpersonationSignal(
            artifactExtensions: [], hadActionToolSuccess: false))
        // 产出含源码(.py) → 不是"唯一文档" → 不触发(交代码门把关)
        XCTAssertFalse(LingShuOutcomeVerification.isDocumentImpersonationSignal(
            artifactExtensions: ["md", "py"], hadActionToolSuccess: false))
    }

    // MARK: - ③ 验收返工引导逐级加厚(升级阶梯并入)

    func testRevisionGuidanceEscalates() {
        let c = "缺少测试"
        let r0 = LingShuCapabilityEscalation.revisionGuidance(round: 0, critique: c)
        let r1 = LingShuCapabilityEscalation.revisionGuidance(round: 1, critique: c)
        let r3 = LingShuCapabilityEscalation.revisionGuidance(round: 3, critique: c)
        XCTAssertTrue(r0.contains(c))
        XCTAssertFalse(r0.contains("结构化引导"), "Rung0 最薄:只回灌意见")
        XCTAssertTrue(r1.contains("结构化引导"), "Rung1:注入结构化引导")
        XCTAssertTrue(r3.contains("确定性兜底"), "Rung2:切确定性兜底")
        XCTAssertTrue(r1.count > r0.count, "升一级 = 在原意见上加厚脚手架")
        XCTAssertFalse(r3.contains("结构化引导"), "Rung2 切到确定性兜底,不是 Rung1")
    }
}
