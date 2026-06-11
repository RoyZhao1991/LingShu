import XCTest
@testable import LingShuMac

final class DirectChatFastPathTests: XCTestCase {
    // MARK: - 升级标记门

    func testGateReleasesNormalTextImmediately() {
        var gate = LingShuTaskEscapeGate(marker: "【任务】")
        // 首字符已能排除标记前缀 → 立即放行，不多攒一拍
        XCTAssertEqual(gate.consume("量子纠缠是"), .release("量子纠缠是"))
        XCTAssertEqual(gate.consume("一种现象"), .release("一种现象"))
    }

    func testGateDetectsMarkerSplitAcrossChunks() {
        var gate = LingShuTaskEscapeGate(marker: "【任务】")
        XCTAssertEqual(gate.consume("【任"), .buffering)
        XCTAssertEqual(gate.consume("务】好的，这就安排。"), .escalate)
    }

    func testGateIgnoresLeadingWhitespaceBeforeMarker() {
        var gate = LingShuTaskEscapeGate(marker: "【任务】")
        XCTAssertEqual(gate.consume("\n 【任务】开工"), .escalate)
    }

    func testGateFlushReturnsNilForMarkerOnlyReply() {
        var gate = LingShuTaskEscapeGate(marker: "【任务】")
        XCTAssertEqual(gate.consume("【任"), .buffering)
        XCTAssertNil(gate.flush(), "残缺标记开头的极短回复按升级处理")
    }

    func testGateReleasesWhenPrefixCannotGrowIntoMarker() {
        var gate = LingShuTaskEscapeGate(marker: "【任务】")
        XCTAssertEqual(gate.consume("【好"), .release("【好"), "「【好」已不可能长成「【任务】」，应立即放行")
    }

    // MARK: - 延迟探针

    func testLatencyProbeRecordsFirstDeltaAndContent() {
        var probe = LingShuStreamLatencyProbe()
        probe.observeDelta(hasContent: false)
        XCTAssertNotNil(probe.firstDeltaAt)
        XCTAssertNil(probe.firstContentAt, "纯思考增量不算首正文")
        probe.observeDelta(hasContent: true)
        XCTAssertNotNil(probe.firstContentAt)
        let summary = probe.summary()
        XCTAssertTrue(summary.contains("首响"))
        XCTAssertTrue(summary.contains("首正文"))
        XCTAssertTrue(summary.contains("完成"))
    }

    // MARK: - 直答/任务本地分类

    @MainActor
    func testLocalClassifierRoutesChatVersusTask() {
        let state = LingShuState()
        XCTAssertFalse(state.isCapabilityCollaborationRequest("你好，今天心情不错"))
        XCTAssertFalse(state.isCapabilityCollaborationRequest("量子纠缠是什么？用两句话解释"))
        XCTAssertTrue(state.isCapabilityCollaborationRequest("帮我做一个三页的介绍杭州的PPT"))
        XCTAssertTrue(state.isCapabilityCollaborationRequest("写一个爬取新闻的爬虫脚本"))
    }
}
