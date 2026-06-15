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

/// 代码交付任务的 git porcelain 解析:源码进代码块、交付物/素材排除、标签映射、重命名取新名、引号清理。
final class CodeChangeSummaryTests: XCTestCase {
    func testParsePorcelainKeepsSourceDropsDeliverables() {
        let porcelain = """
         M Sources/State/LingShuState.swift
        A  Sources/New.swift
        ?? 演示.pptx
        ?? assets/cover.jpg
         M report.pdf
        ?? notes.md
        """
        let changes = LingShuState.parseGitPorcelain(porcelain)
        let paths = changes.map(\.path)
        XCTAssertTrue(paths.contains("Sources/State/LingShuState.swift"))
        XCTAssertTrue(paths.contains("Sources/New.swift"))
        XCTAssertTrue(paths.contains("notes.md"))
        XCTAssertFalse(paths.contains("演示.pptx"), "交付物 pptx 不进代码块")
        XCTAssertFalse(paths.contains("assets/cover.jpg"), "assets 素材不进代码块")
        XCTAssertFalse(paths.contains("report.pdf"), "pdf 不进代码块")
    }

    func testParsePorcelainLabelsAndRename() {
        let changes = LingShuState.parseGitPorcelain("R  old.swift -> Sources/new.swift\n D gone.swift")
        XCTAssertEqual(changes.first(where: { $0.path == "Sources/new.swift" })?.label, "重命名")
        XCTAssertEqual(changes.first(where: { $0.path == "gone.swift" })?.label, "删除")
    }

    func testParsePorcelainEmptyWhenCleanOrOnlyDeliverables() {
        XCTAssertTrue(LingShuState.parseGitPorcelain("").isEmpty)
        XCTAssertTrue(LingShuState.parseGitPorcelain("?? out.pptx\n?? assets/x.png").isEmpty, "只有交付物→代码块为空")
    }
}
