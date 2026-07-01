import XCTest
@testable import LingShuMac

/// 「演示与答疑」编排引擎守卫(mock 钩子,0 真模型/0 真 UI):脚本生成 / 照念 / 答疑暂停续演 / 多文档连播。
@MainActor
final class PresentationControllerTests: XCTestCase {

    final class Recorder {
        var navigated: [Int] = []
        var spoken: [String] = []
        var announced: [String] = []                       // announce 钩子(开场白 / 篇间播报)
        var events: [String] = []                          // 发声时间线(ann:… / say:…)——验证开场白排在首页讲稿**之前**
        var fullscreen: [Bool] = []
        var shownDocs: [String] = []
        var interrupts = 0
        var prefetched: [String] = []                      // 预合成下一页的调用(验证翻页前预取)
        var narrateCalls: [LingShuPresentationPace] = []   // 每次生成讲稿用的档(验证切档重生成)
        var stopAfterSpeak: Int?
        var pauseAfterSpeak: Int?
        weak var controller: LingShuPresentationController?
    }

    private func make(_ pages: [String: [String]], _ rec: Recorder) -> LingShuPresentationController {
        let c = LingShuPresentationController()
        rec.controller = c
        c.install(.init(
            loadPages: { pages[$0] ?? [] },
            showDocument: { rec.shownDocs.append($0) },
            narrate: { v, _, _, _, p in rec.narrateCalls.append(p); return "讲:\(v)" },
            navigate: { rec.navigated.append($0) },
            speak: { t in
                rec.spoken.append(t)
                rec.events.append("say:\(t)")
                if rec.spoken.count == rec.pauseAfterSpeak { rec.controller?.requestPauseForQA() }
                if rec.spoken.count == rec.stopAfterSpeak { rec.controller?.requestStop() }
            },
            prefetchNarration: { rec.prefetched.append($0) },
            announce: { rec.announced.append($0); rec.events.append("ann:\($0)") },
            setFullscreen: { rec.fullscreen.append($0) },
            note: { _, _ in },
            interruptAudio: { rec.interrupts += 1 }
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

    /// 开场白(play(opening:))**只念一次**、且排在首页讲稿**之前**(同发声通道串行)——根治"开场白被首页讲稿掐断"。
    func testOpeningAnnouncedOnceBeforeFirstNarration() async {
        let rec = Recorder()
        let c = make(["/a.pdf": ["p0", "p1"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play(opening: "好的,我开始演示了。有问题随时打断我。")
        XCTAssertEqual(rec.announced.filter { $0 == "好的,我开始演示了。有问题随时打断我。" }.count, 1, "开场白只念一次")
        // 时间线**前三拍**:开场白 → 首页讲稿 → 第二页讲稿,开场白严格在首页讲稿之前(同通道串行,不互相掐)。
        // (其后还有一条收尾 announce,不在此断言范围。)
        XCTAssertEqual(Array(rec.events.prefix(3)),
                       ["ann:好的,我开始演示了。有问题随时打断我。", "say:讲:p0", "say:讲:p1"],
                       "开场白念完才念首页讲稿")
        XCTAssertEqual(c.phase, .finished)
    }

    /// 跳页续演:`resume(seekTo:opening:)` 先**翻到目标页**(画面即时响应)→ 念确认句 → **再念该页讲稿**(确认排在讲稿前,不互相掐)。
    /// 根治实测 bug:从第一页重讲,第一页画面到了但没念,直接跳第二页——确认句把第一页讲稿掐了。
    func testSeekResumeFlipsThenAnnouncesThenNarrates() async {
        let rec = Recorder()
        rec.pauseAfterSpeak = 2                        // 念完前2页后暂停
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        XCTAssertEqual(c.phase, .pausedForQA)
        rec.pauseAfterSpeak = nil
        rec.events.removeAll(); rec.navigated.removeAll()
        await c.resume(seekTo: 0, opening: "好,翻到第1页。")
        XCTAssertEqual(rec.navigated.first, 0, "先翻到目标页(第1页)——画面即时响应")
        XCTAssertEqual(rec.events.first, "ann:好,翻到第1页。", "翻页后先念确认句")
        XCTAssertEqual(rec.events.dropFirst().first, "say:讲:p0", "确认念完**才**念第1页讲稿(该页没被跳过)")
        XCTAssertTrue(rec.prefetched.contains("讲:p0"), "跳进来的目标页讲稿在念确认句时就后台预合成了(消'翻页后较长停顿')")
    }

    /// 续演/连播**不带开场白**:resume / confirmAndPlayNext 走默认 play()(opening=nil),不应再蹦出开场白。
    func testResumeAndNextDocHaveNoOpening() async {
        let rec = Recorder()
        rec.pauseAfterSpeak = 1
        let c = make(["/a.pdf": ["p0", "p1"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play(opening: "开场")
        rec.pauseAfterSpeak = nil
        await c.resume()
        XCTAssertEqual(rec.announced.filter { $0 == "开场" }.count, 1, "开场白只在首演念一次,续演(resume)不再念")
    }

    func testPauseDuringPlayPreservesPlayhead() async {
        let rec = Recorder()
        rec.pauseAfterSpeak = 1                      // 念完第1页后请求暂停
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        XCTAssertEqual(rec.spoken, ["讲:p0"], "停在当前页,没继续往后念")
        XCTAssertEqual(c.phase, .pausedForQA)
        XCTAssertEqual(c.queue.currentScript?.currentBeat?.pageIndex, 0, "**停在当前页(第1页)不前进**,继续时从这页接着念")
    }

    func testResumeContinuesFromPause() async {
        let rec = Recorder()
        rec.pauseAfterSpeak = 1
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        rec.pauseAfterSpeak = nil                    // 答疑结束,不再暂停
        await c.resume()                             // 从暂停页(第1页)续:重念当前页再往后
        XCTAssertEqual(rec.spoken, ["讲:p0", "讲:p0", "讲:p1", "讲:p2"], "从暂停页p0接着念(p0被打断没念完→重念),再往后")
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

    func testStopHaltsPlaybackAndCutsAudio() async {
        let rec = Recorder()
        rec.stopAfterSpeak = 1                       // 念完第1页后请求停止(模拟用户取消)
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        XCTAssertEqual(rec.spoken, ["讲:p0"], "停止后**不再念下一页**——根治取消后音频还在播")
        XCTAssertEqual(c.phase, .finished)
        XCTAssertGreaterThanOrEqual(rec.interrupts, 1, "停止时掐了当前 TTS")
    }

    func testPrefetchesNextPageDuringPlayback() async {
        let rec = Recorder()
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        await c.play()
        // 念每页前预取下一页:念p0时预取p1、念p1时预取p2;最后一页无下一页不预取。
        XCTAssertEqual(rec.prefetched, ["讲:p1", "讲:p2"], "翻页前逐页预合成下一页(最后一页除外)")
    }

    func testSetPaceRegeneratesSubsequentBeatsLazily() async {
        let rec = Recorder()
        let c = make(["/a.pdf": ["p0", "p1", "p2"]], rec)
        await c.buildQueue(documentPaths: ["/a.pdf"])
        XCTAssertEqual(rec.narrateCalls, [.detailed, .detailed, .detailed], "建队列时按默认详细档逐页生成")
        c.setPace(.brief)                       // 切快速档
        XCTAssertEqual(c.pace, .brief)
        await c.play()                          // 播放时每页 narrationPace(.detailed)!=pace(.brief) → 按快速档重生成
        XCTAssertEqual(Array(rec.narrateCalls.suffix(3)), [.brief, .brief, .brief], "切快速档后,后续每页都按快速档重生成讲稿")
    }
}
