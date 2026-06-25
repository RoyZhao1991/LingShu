import XCTest
@testable import LingShuMac

/// 独立 checker 的结论判定(纯函数):maker≠checker 复核结论文本 → 通过/不通过。
final class IndependentCheckerTests: XCTestCase {

    func testPassVerdicts() {
        XCTAssertTrue(LingShuState.checkerVerdictPassed("通过\n所有测试全绿"))
        XCTAssertTrue(LingShuState.checkerVerdictPassed("通过"))
        XCTAssertTrue(LingShuState.checkerVerdictPassed("PASS - 7 tests ok"))
        XCTAssertTrue(LingShuState.checkerVerdictPassed("✅ 验收通过,产出达标"))
    }

    func testFailVerdicts() {
        XCTAssertFalse(LingShuState.checkerVerdictPassed("不通过\n缺少边界处理"))
        XCTAssertFalse(LingShuState.checkerVerdictPassed("未通过:测试 2 项失败"))
        XCTAssertFalse(LingShuState.checkerVerdictPassed("NOT PASS - file missing"))
        XCTAssertFalse(LingShuState.checkerVerdictPassed("FAIL: test_x errored"))
        XCTAssertFalse(LingShuState.checkerVerdictPassed("一些无关的描述性文字没有结论"))
    }
}
