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
}
