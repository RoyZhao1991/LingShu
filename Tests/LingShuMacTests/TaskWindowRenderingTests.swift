import XCTest
@testable import LingShuMac

/// 子任务窗口对齐 codex 的纯逻辑测试:行 diff + 撤销还原 + 录制净化 + 工具卡摘要。
final class TaskWindowRenderingTests: XCTestCase {

    // MARK: 行 diff

    func testLineDiffCountsAddedRemoved() {
        let result = LingShuLineDiff.compute(old: "a\nb\nc", new: "a\nB\nc\nd")
        XCTAssertEqual(result.added, 2)    // B、d
        XCTAssertEqual(result.removed, 1)  // b
    }

    func testReconstructOldRoundTripsModify() {
        let old = "line1\nline2\nline3"
        let new = "line1\nLINE2-changed\nline3\nline4"
        let result = LingShuLineDiff.compute(old: old, new: new)
        XCTAssertEqual(LingShuLineDiff.reconstructOld(fromUnified: result.unified), old, "撤销需能从 diff 无损还原改前内容")
    }

    func testCreatedFileDiffIsAllAdditionsAndReconstructsEmpty() {
        let result = LingShuLineDiff.compute(old: "", new: "x\ny")
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(LingShuLineDiff.reconstructOld(fromUnified: result.unified), "")
    }

    func testTruncatedDiffIsNotUndoable() {
        let old = (0..<500).map { "old\($0)" }.joined(separator: "\n")
        let new = (0..<500).map { "new\($0)" }.joined(separator: "\n")
        let result = LingShuLineDiff.compute(old: old, new: new, maxLines: 240)
        XCTAssertTrue(LingShuLineDiff.isTruncated(result.unified))
        XCTAssertNil(LingShuLineDiff.reconstructOld(fromUnified: result.unified), "截断 diff 不可无损还原 → 禁止撤销")
    }

    // MARK: 录制净化(身份铁律 + 干净渲染)

    func testSanitizeStripsModelNameLeak() {
        XCTAssertEqual(LingShuTaskMessageFormatting.sanitize("由 MiniMax 提供支持"), "由 灵枢 提供支持")
        XCTAssertFalse(LingShuTaskMessageFormatting.sanitize("我是 Qwen / 通义千问").contains("Qwen"))
    }

    func testSanitizeCollapsesRawToolCallsJSON() {
        let raw = "{\"role\":\"assistant\",\"name\":\"MiniMax AI\",\"tool_calls\":[{\"id\":\"c1\"}]}"
        XCTAssertEqual(LingShuTaskMessageFormatting.sanitize(raw), "（已发起工具调用）")
    }

    // MARK: 工具卡摘要

    func testToolCallSummaryReadsCommandFirstLine() {
        XCTAssertEqual(LingShuTaskMessageFormatting.toolCallSummary(tool: "run_command", arguments: ["command": "ls -la\necho hi"]), "ls -la")
        XCTAssertEqual(LingShuTaskMessageFormatting.toolCallSummary(tool: "write_file", arguments: ["path": "/tmp/a.txt", "content": "x"]), "写入 /tmp/a.txt")
    }

    func testPrettyArgumentsUnwrapsMCPEnvelope() {
        let pretty = LingShuTaskMessageFormatting.prettyArguments(["arguments_json": "{\"q\":\"灵枢\"}"])
        XCTAssertTrue(pretty.contains("\"q\""))
        XCTAssertTrue(pretty.contains("灵枢"))
    }
}
