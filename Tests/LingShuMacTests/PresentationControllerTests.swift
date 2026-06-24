import XCTest
@testable import LingShuMac

/// 「演示与答疑」编排引擎守卫(mock 钩子,0 真模型/0 真 UI):脚本生成 / 照念 / 答疑暂停续演 / 多文档连播。
@MainActor
final class PresentationControllerTests: XCTestCase {

    final class Recorder {
        var navigated: [Int] = []
        var spoken: [String] = []
        var fullscreen: [Bool] = []
        var shownDocs: [String] = []
        var pauseAfterSpeak: Int?
        weak var controller: LingShuPresentationController?
    }

    private func make(_ pages: [String: [String]], _ rec: Recorder) -> LingShuPresentationController {
        let c = LingShuPresentationController()
        rec.controller = c
        c.install(.init(
            loadPages: { pages[$0] ?? [] },
            showDocument: { rec.shownDocs.append($0) },
            narrate: { v, _, _, _ in "讲:\(v)" },
            navigate: { rec.navigated.append($0) },
            speak: { t in
                rec.spoken.append(t)
                if rec.spoken.count == rec.pauseAfterSpeak { rec.controller?.requestPauseForQA() }
            },
            setFullscreen: { rec.fullscreen.append($0) },
            note: { _, _ in }
        ))
        return c
    }

    func testBuildQueueGeneratesScripts() async {
        let rec = Recorder()
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        XCTAssertEqual(c.queue.currentScript?.beatCount, 3)
        XCTAssertEqual(c.queue.currentScript?.beats.first?.narration, "讲:p0", "讲稿预生成")
    }

    func testPlaySingleDocWalksAllBeatsAndFinishes() async {
        let rec = Recorder()
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        XCTAssertEqual(rec.navigated, [0, 1, 2])
        XCTAssertEqual(rec.spoken, ["讲:p0", "讲:p1", "讲:p2"])
        XCTAssertEqual(c.phase, .finished)
        XCTAssertEqual(rec.fullscreen.first, true, "演示开始进全屏")
        XCTAssertEqual(rec.fullscreen.last, false, "演完退全屏")
    }

    func testPauseDuringPlayPreservesPlayhead() async {
        let rec = Recorder()
        rec.pauseAfterSpeak = 1                      // 念完第1页后请求暂停
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        XCTAssertEqual(rec.spoken, ["讲:p0"], "停在第2拍前,只念了第1页")
        XCTAssertEqual(c.phase, .pausedForQA)
        XCTAssertEqual(c.queue.currentScript?.currentBeat?.pageIndex, 1, "播放头停在第2页,不丢位")
    }

    func testResumeContinuesFromPause() async {
        let rec = Recorder()
        rec.pauseAfterSpeak = 1
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        rec.pauseAfterSpeak = nil                    // 答疑结束,不再暂停
        await c.resume()                             // 从当前位置(第2页)续
        XCTAssertEqual(rec.spoken, ["讲:p0", "讲:p1", "讲:p2"])
        XCTAssertEqual(c.phase, .finished)
    }

    func testResumeWithSeekReplaysFromSpecifiedPage() async {
        let rec = Recorder()
        rec.pauseAfterSpeak = 2                       // 念完前2页后暂停
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        XCTAssertEqual(c.phase, .pausedForQA)
        rec.pauseAfterSpeak = nil
        await c.resume(seekTo: 0)                      // 用户说「从第1页重讲」
        XCTAssertEqual(rec.spoken, ["讲:p0", "讲:p1", "讲:p0", "讲:p1", "讲:p2"], "从指定页重新念")
        XCTAssertEqual(c.phase, .finished)
    }

    func testMultiDocAwaitsConfirmThenPlaysNext() async {
        let rec = Recorder()
        let c = make(["/a.pdf": ["a0", "a1"], "/b.pdf": ["b0"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf", "/b.pdf"])
        await c.play()
        XCTAssertEqual(rec.spoken, ["讲:a0", "讲:a1"], "先演完第一篇")
        XCTAssertEqual(c.phase, .awaitingNextDoc, "停下等用户确认切下一篇(像连播)")
        await c.confirmAndPlayNext()
        XCTAssertEqual(rec.spoken, ["讲:a0", "讲:a1", "讲:b0"], "确认后演第二篇")
        XCTAssertEqual(c.phase, .finished)
        XCTAssertEqual(rec.shownDocs, ["/a.pdf", "/b.pdf"], "每篇演前都先显示出来,不串台")
    }
}
