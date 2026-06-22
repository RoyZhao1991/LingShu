import XCTest
@testable import LingShuMac

/// 「审查」面板 unified diff 解析(纯逻辑,模型无关)。
final class WorkspaceDiffParseTests: XCTestCase {

    func testParsesAddDeleteContextAndHunk() {
        let raw = """
        diff --git a/foo.swift b/foo.swift
        index 111..222 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        """
        let lines = LingShuWorkspaceDiffView.parseDiff(raw)
        // diff/index/---/+++ 头被过滤;保留 @@ + 上下文 + 增删
        XCTAssertTrue(lines.contains { $0.kind == .hunk && $0.text.hasPrefix("@@") })
        XCTAssertEqual(lines.filter { $0.kind == .add }.map(\.text), ["let b = 3"])
        XCTAssertEqual(lines.filter { $0.kind == .del }.map(\.text), ["let b = 2"])
        XCTAssertEqual(lines.filter { $0.kind == .ctx }.map(\.text), ["let a = 1", "let c = 4"])
        XCTAssertFalse(lines.contains { $0.text.hasPrefix("diff ") || $0.text.hasPrefix("index ") }, "diff/index 头应被过滤")
    }

    func testEmptyDiffYieldsNoLines() {
        XCTAssertTrue(LingShuWorkspaceDiffView.parseDiff("").isEmpty)
    }

    func testGutterAndPlainTextStripLeadingMarker() {
        let lines = LingShuWorkspaceDiffView.parseDiff("+added\n-removed\n unchanged")
        XCTAssertEqual(lines[0].kind.gutter, "+")
        XCTAssertEqual(lines[0].text, "added")          // 前导 + 已剥离
        XCTAssertEqual(lines[1].text, "removed")        // 前导 - 已剥离
        XCTAssertEqual(lines[2].text, "unchanged")      // 前导空格已剥离
    }
}
