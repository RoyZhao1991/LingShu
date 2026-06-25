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

    // MARK: - 「演示文档」确定性路由检测器

    func testDetectPresentationRequestExtractsPaths() {
        let r = LingShuState.detectPresentationRequest("把 /tmp/a.pdf 这个文档正式演示讲解一下")
        XCTAssertEqual(r, ["/tmp/a.pdf"])
    }

    func testDetectPresentationRequestMultipleDocs() {
        let r = LingShuState.detectPresentationRequest("依次演示 /a/x.pptx 和 /b/y.pdf")
        XCTAssertEqual(r, ["/a/x.pptx", "/b/y.pdf"])
    }

    func testDetectPresentationRequestNeedsIntentWord() {
        // 有路径但无演示意图 → 不拦(交大脑常规处理)。
        XCTAssertNil(LingShuState.detectPresentationRequest("帮我改一下 /tmp/a.pdf 的内容"))
    }

    func testDetectPresentationRequestNeedsPath() {
        // 有演示意图但无文档路径 → 不拦。
        XCTAssertNil(LingShuState.detectPresentationRequest("给我演示一下你的能力"))
    }
}

// 暂停/继续/停止 意图判定(删除鼠标打断后,暂停走语音命令)
final class PresentationIntentTests: XCTestCase {
    func testPauseIntentNotStop() {
        XCTAssertTrue(LingShuState.isPresentationPauseIntent("暂停一下"))
        XCTAssertTrue(LingShuState.isPresentationPauseIntent("先停一下"))
        XCTAssertFalse(LingShuState.isPresentationStopIntent("暂停一下"), "「暂停」不能被当成停止")
        XCTAssertFalse(LingShuState.isPresentationStopIntent("停一下"))
    }
    func testStopIntentStillWorks() {
        XCTAssertTrue(LingShuState.isPresentationStopIntent("停止演示"))
        XCTAssertTrue(LingShuState.isPresentationStopIntent("不看了"))
        XCTAssertTrue(LingShuState.isPresentationStopIntent("退出演示"))
    }
    func testResumeIntent() {
        XCTAssertTrue(LingShuState.isPresentationResumeIntent("继续"))
        XCTAssertTrue(LingShuState.isPresentationResumeIntent("接着讲"))
        XCTAssertFalse(LingShuState.isPresentationResumeIntent("这页讲的是什么"), "普通问题不算继续")
    }
    @MainActor func testSeekIntentFallback() {
        if case .seek(let p) = LingShuState.fallbackPresentationIntent("跳到第5页").intent { XCTAssertEqual(p, 5) }
        else { XCTFail("「跳到第5页」应判为 seek(5)") }
        if case .seek(let p) = LingShuState.fallbackPresentationIntent("翻到第3页").intent { XCTAssertEqual(p, 3) }
        else { XCTFail("「翻到第3页」应判为 seek(3)") }
        if case .question = LingShuState.fallbackPresentationIntent("这页讲的是啥").intent {} else { XCTFail("普通问题不该判成跳页") }
    }
}
