import XCTest
@testable import LingShuMac

/// edit_file 多策略匹配级联测试(opencode 借鉴点 #1)。覆盖:精确/不唯一/找不到/恒等/空,
/// 以及容错策略:逐行去空白、空白归一、块锚点(中段略有出入),加 disproportionate 守卫与 levenshtein。
final class EditReplacerTests: XCTestCase {

    func testExactUniqueReplace() {
        XCTAssertEqual(LingShuEditReplacer.replace(content: "a\nb\nc\n", oldString: "b", newString: "B"), .replaced("a\nB\nc\n"))
    }

    func testIdenticalAndEmpty() {
        XCTAssertEqual(LingShuEditReplacer.replace(content: "a", oldString: "x", newString: "x"), .identical)
        XCTAssertEqual(LingShuEditReplacer.replace(content: "a", oldString: "", newString: "y"), .emptyOld)
    }

    func testNotFound() {
        XCTAssertEqual(LingShuEditReplacer.replace(content: "a\nb\n", oldString: "zzz", newString: "y"), .notFound)
    }

    func testMultipleOccurrences() {
        XCTAssertEqual(LingShuEditReplacer.replace(content: "x\nx\n", oldString: "x", newString: "y"), .multiple)
    }

    func testLineTrimmedToleratesMissingIndent() {
        // 文件里有缩进,模型给的 old 没带缩进 → 精确失败,逐行去空白命中。
        let content = "func f() {\n        let v = compute()\n        return v\n}\n"
        let old = "let v = compute()\nreturn v"
        let r = LingShuEditReplacer.replace(content: content, oldString: old, newString: "let v = compute2()\nreturn v")
        guard case .replaced(let updated) = r else { return XCTFail("应命中逐行去空白,实际 \(r)") }
        XCTAssertTrue(updated.contains("compute2()"))
        XCTAssertTrue(updated.contains("func f() {"))
    }

    func testWhitespaceNormalizedToleratesInnerSpaces() {
        let content = "let  x   =    1\n"
        let old = "let x = 1"
        let r = LingShuEditReplacer.replace(content: content, oldString: old, newString: "let x = 2")
        guard case .replaced(let updated) = r else { return XCTFail("应命中空白归一,实际 \(r)") }
        XCTAssertTrue(updated.contains("let x = 2"))
    }

    func testBlockAnchorMatchesWhenMiddleSlightlyDiffers() {
        let content = "begin block\n  step one here\n  step two here\n  step three here\nend block\n"
        let old = "begin block\n  step one heer\n  step two here\n  step three here\nend block"   // 中段 typo
        let r = LingShuEditReplacer.replace(content: content, oldString: old, newString: "begin block\n  replaced\nend block")
        guard case .replaced(let updated) = r else { return XCTFail("应命中块锚点,实际 \(r)") }
        XCTAssertTrue(updated.contains("replaced"))
        XCTAssertFalse(updated.contains("step one"))
    }

    func testDisproportionateGuard() {
        XCTAssertTrue(LingShuEditReplacer.isDisproportionate(search: "1\n2\n3\n4\n5\n6\n7", oldString: "1\n2"))
        XCTAssertFalse(LingShuEditReplacer.isDisproportionate(search: "abc", oldString: "abd"))
    }

    func testLevenshtein() {
        XCTAssertEqual(LingShuEditReplacer.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(LingShuEditReplacer.levenshtein("", "abc"), 3)
        XCTAssertEqual(LingShuEditReplacer.levenshtein("same", "same"), 0)
    }
}
