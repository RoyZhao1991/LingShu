import XCTest
@testable import LingShuMac

/// 复现并锁死"0 达标 / 0 未达标"那个 bug：评审官把 ✅/❌ 写在加粗标题后、说明里也夹杂勾叉，
/// 行首计数会数成 0。结构化统计行 `PASS=N FAIL=M` 根治。
final class ChecklistTallyTests: XCTestCase {
    func testCountsFromStructuredTallyNotScatteredMarkers() {
        let critique = """
        ## 逐条核对（A1–A5）
        **A1 页数合规**：⏸ 无法仅凭草稿断言 ✅
        草稿未列出页数；若落在区间外则 ❌。→ 修正建议：补实测页数。
        **A2 时长合规**：❌ 不通过（7 分钟 > 5 分钟上限）
        **A3 内容完整**：✅ 通过 P2–P7 已覆盖 6 章节
        **A4 质量检查**：⏸ 无法仅凭草稿断言 ✅
        **A5 交付规范**：❌ 不通过（草稿仅一句"全部 ✅ PASS"）
        核对统计 PASS=3 FAIL=2
        结论：需修正
        """
        let v = LingShuChecklistVerdict.parse(critique)
        XCTAssertEqual(v.passedCount, 3)
        XCTAssertEqual(v.failedCount, 2)
        XCTAssertFalse(v.allPassed)
    }

    func testTallyPassZeroFailuresWithDeclarationPasses() {
        let v = LingShuChecklistVerdict.parse("""
        **A1**：✅
        核对统计 PASS=5 FAIL=0
        结论：通过
        """)
        XCTAssertTrue(v.allPassed)
        XCTAssertEqual(v.failedCount, 0)
    }

    func testFallbackStillWorksWithoutTally() {
        let v = LingShuChecklistVerdict.parse("""
        ✅ 标准一
        ❌ 标准二：缺验收口径
        结论：需修正
        """)
        XCTAssertEqual(v.failedCount, 1)
        XCTAssertFalse(v.allPassed)
    }
}
