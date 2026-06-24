import XCTest
@testable import LingShuMac

/// 「演示与答疑」纯逻辑守卫(0 模型依赖):脚本播放头 / 视频流式 seek / 进度条 / 多文档队列。
final class PresentationScriptTests: XCTestCase {

    private func script(_ n: Int, playhead: Int = 0) -> LingShuPresentationScript {
        let beats = (0..<n).map { LingShuPresentationBeat(pageIndex: $0, verbatim: "第\($0)页原文", narration: "第\($0)页讲稿") }
        return .init(documentPath: "/x/doc.pdf", title: "doc", beats: beats, playhead: playhead)
    }

    func testAdvanceWalksThenCompletes() {
        var s = script(3)
        XCTAssertEqual(s.currentBeat?.pageIndex, 0)
        XCTAssertEqual(s.advance()?.pageIndex, 1)
        XCTAssertEqual(s.advance()?.pageIndex, 2)
        XCTAssertNil(s.advance(), "念完最后一拍后再前进 → nil(演完)")
        XCTAssertTrue(s.isComplete)
    }

    func testSeekClampsAndIsVideoLike() {
        var s = script(5)
        XCTAssertEqual(s.seek(to: 3)?.pageIndex, 3, "拖到第4页")
        XCTAssertEqual(s.seek(to: 99)?.pageIndex, 4, "拖过尾 → 夹到最后一页")
        XCTAssertEqual(s.seek(to: -5)?.pageIndex, 0, "拖到负 → 夹到第一页")
    }

    func testProgressIsTextProgressBar() {
        var s = script(4)
        XCTAssertEqual(s.progress, 0.0, accuracy: 0.001)
        s.advance(); XCTAssertEqual(s.progress, 0.25, accuracy: 0.001)
        s.seek(to: 2); XCTAssertEqual(s.progress, 0.5, accuracy: 0.001)
        // 念到尾
        s.advance(); s.advance()
        XCTAssertEqual(s.progress, 1.0, accuracy: 0.001)
    }

    func testResumeFromCurrentAfterQA() {
        // 模拟:念到第3拍被答疑打断 → 答完从当前位置继续(playhead 不变)。
        var s = script(5, playhead: 2)
        XCTAssertEqual(s.currentBeat?.pageIndex, 2)
        // 答疑期间不动 playhead;答完直接念 currentBeat。
        XCTAssertEqual(s.currentBeat?.pageIndex, 2, "答疑后从当前位置续,不丢位")
    }

    func testResumeFromSpecifiedPositionAfterQA() {
        var s = script(5, playhead: 2)
        // 用户答疑后说「从第1页重讲」→ seek 回去。
        XCTAssertEqual(s.seek(to: 0)?.pageIndex, 0)
    }

    func testEmptyScriptIsComplete() {
        let s = script(0)
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.progress, 1.0, accuracy: 0.001)
        XCTAssertNil(s.currentBeat)
    }

    func testSetNarrationFillsByPage() {
        var s = script(3)
        s.setNarration("改写的讲稿", forPageIndex: 1)
        XCTAssertEqual(s.beats[1].narration, "改写的讲稿")
        XCTAssertEqual(s.beats[0].narration, "第0页讲稿", "只改指定页")
    }

    // MARK: - 多文档连播队列

    func testQueueAdvancesLikePlaylist() {
        var q = LingShuPresentationQueue(scripts: [script(2), script(3), script(1)])
        XCTAssertEqual(q.position.current, 1)
        XCTAssertEqual(q.position.total, 3)
        XCTAssertTrue(q.hasNext)
        XCTAssertEqual(q.advanceToNext()?.beatCount, 3, "切到第2篇")
        XCTAssertEqual(q.advanceToNext()?.beatCount, 1, "切到第3篇")
        XCTAssertFalse(q.hasNext)
        XCTAssertNil(q.advanceToNext(), "最后一篇后 → nil")
    }

    func testQueueWriteBackPreservesPlayhead() {
        var q = LingShuPresentationQueue(scripts: [script(4)])
        var cur = q.currentScript!
        cur.seek(to: 2)
        q.updateCurrent(cur)
        XCTAssertEqual(q.currentScript?.progress ?? 0, 0.5, accuracy: 0.001, "对当前脚本的 seek 回写进队列")
    }

    func testEmptyQueue() {
        var q = LingShuPresentationQueue()
        XCTAssertNil(q.currentScript)
        XCTAssertFalse(q.hasNext)
        XCTAssertNil(q.advanceToNext())
    }
}
