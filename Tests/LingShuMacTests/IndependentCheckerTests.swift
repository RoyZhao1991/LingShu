import XCTest
@testable import LingShuMac

/// 独立 checker 的结论判定(纯函数):maker≠checker 复核结论 JSON → 通过/不通过。
final class IndependentCheckerTests: XCTestCase {

    func testPassVerdictsFromJSON() {
        let verdict = """
        {
          "passed": true,
          "confidence": 0.93,
          "summary": "测试全绿,代码质量达标",
          "checks": [{"name":"测试","passed":true,"reason":"pytest 通过"}],
          "blockingIssues": [],
          "evidence": ["pytest -q"],
          "needsUser": null
        }
        """
        XCTAssertTrue(LingShuState.checkerVerdictPassed(verdict))
    }

    func testFailVerdictsFromJSON() {
        let verdict = """
        {
          "passed": false,
          "confidence": 0.88,
          "summary": "有阻断问题",
          "checks": [{"name":"边界处理","passed":false,"reason":"空输入会崩"}],
          "blockingIssues": ["空输入会崩"],
          "evidence": ["复测失败"],
          "needsUser": null
        }
        """
        XCTAssertFalse(LingShuState.checkerVerdictPassed(verdict))
    }

    func testEmbeddedJSONVerdictParsesButLegacyTextDoesNot() {
        XCTAssertTrue(LingShuState.checkerVerdictPassed("```json\n{\"passed\":true,\"summary\":\"ok\",\"checks\":[],\"blockingIssues\":[],\"evidence\":[]}\n```"))

        XCTAssertFalse(LingShuState.checkerVerdictPassed("通过\n所有测试全绿"))
        XCTAssertFalse(LingShuState.checkerVerdictPassed("PASS - 7 tests ok"))
        XCTAssertFalse(LingShuState.checkerVerdictPassed("✅ 验收通过,产出达标"))
        XCTAssertFalse(LingShuState.checkerVerdictPassed("一些无关的描述性文字没有结论"))
    }

    func testVerdictRenderingKeepsActionableIssues() {
        let parsed = LingShuCheckerVerdict.parse("""
        {"passed":false,"summary":"质量未过","checks":[{"name":"代码质量","passed":false,"reason":"函数过长"}],"blockingIssues":["函数过长"],"evidence":["read_file add.py"],"needsUser":null}
        """)
        XCTAssertEqual(parsed?.passed, false)
        XCTAssertTrue(parsed?.renderedSummary.contains("函数过长") == true)
    }

    func testConversationSummaryTurnsVerdictIntoReadableMarkdown() {
        let raw = #"{"passed":true,"summary":"图标已生成并通过验收","checks":[{"name":"输出规格","passed":true,"reason":"PNG, 254 x 254,透明背景"},{"name":"落盘位置","passed":true,"reason":"文件存在"}],"blockingIssues":[],"evidence":["file 输出确认 PNG"],"needsUser":null}"#
        let summary = LingShuCheckerVerdict.parse(raw)?.conversationSummary ?? ""

        XCTAssertTrue(summary.contains("**验收明细**"))
        XCTAssertTrue(summary.contains("- ✅ **输出规格**"))
        XCTAssertTrue(summary.contains("**核验依据**"))
        XCTAssertFalse(summary.contains("\"passed\""))
        XCTAssertFalse(summary.contains("{\""))
    }

    func testRolePipelineBubbleNeverAppendsRawProtocolPayload() {
        let bubble = LingShuState.rolePipelineBubbleText(
            route: "🔧 **协作流程**\n工程执行专家（Codex） → 评审官（灵枢）",
            passed: true,
            stopped: false,
            unavailableNotice: nil,
            reviewSummary: "图标已生成。\n\n**验收明细**\n- ✅ **输出规格**：PNG"
        )

        XCTAssertTrue(bubble.contains("已完成并通过验收"))
        XCTAssertTrue(bubble.contains("**验收明细**"))
        XCTAssertFalse(bubble.contains("blockingIssues"))
        XCTAssertFalse(bubble.contains("samplesPerPixel"))
    }
}
