import Foundation

/// 「演示与答疑」插件的**编排引擎**:把"通读→生成脚本→照脚本念→答疑暂停→视频流式续演→多文档连播"
/// 收口到一处。依赖经**注入式钩子**给(生成讲稿/翻页/念稿/取每页正文),故编排逻辑可单测、又便于接进 `LingShuState`。
///
/// 与 `LingShuPreviewController` 分工:预览控制器管"开窗/翻页/抽文字"(视觉),本控制器管"演示流程编排"(节奏/脚本/答疑/队列)。
@MainActor
final class LingShuPresentationController: ObservableObject {

    /// 注入钩子集——由 LingShuState 在装配时填真实现(speak/preview/控制面 LLM);测试可填 mock。
    /// 全标 `@MainActor`:本控制器即 @MainActor,钩子内可直接访问主线程状态,免到处包 MainActor.run。
    struct Hooks {
        /// 打开文档并返回每页真实正文(0-based 顺序);失败返回空。脚本生成阶段用。
        var loadPages: @MainActor (_ path: String) async -> [String]
        /// 把某篇文档**显示出来**(演示该篇前调,保证窗里是当前这篇——多文档连播必需)。
        var showDocument: @MainActor (_ path: String) async -> Void
        /// 据一页正文 + **讲解档**生成该页讲稿(控制面 LLM)。pace 决定深度(详细/快速/概要)。
        var narrate: @MainActor (_ verbatim: String, _ pageNumber: Int, _ total: Int, _ title: String, _ pace: LingShuPresentationPace) async -> String
        /// 把预览翻到某页(0-based)。
        var navigate: @MainActor (_ pageIndex: Int) async -> Void
        /// 念一段讲稿(**阻塞到念完**,这样答疑能在两拍之间插入)。
        var speak: @MainActor (_ text: String) async -> Void
        /// **预合成下一页讲稿**(可选):当前页念时后台先把下一页 TTS 合成好,翻页即时起播、不再现等首包。
        var prefetchNarration: (@MainActor (_ text: String) -> Void)? = nil
        /// **演示元提示**(可选,篇间「说继续切下一篇」/ 全部收尾):与逐页讲稿 speak 区分,出声 + 进聊天。
        var announce: (@MainActor (_ text: String) async -> Void)? = nil
        /// 进/退全屏演示。
        var setFullscreen: @MainActor (_ on: Bool) async -> Void
        /// 落一条状态/旁白(trace),供观测。
        var note: @MainActor (_ title: String, _ detail: String) -> Void
        /// **立刻掐掉正在播的 TTS**(取消/答疑打断时用;像视频播放器停止就静音)。
        var interruptAudio: @MainActor () -> Void
    }

    @Published private(set) var phase: LingShuPresentationPhase = .idle
    @Published private(set) var queue = LingShuPresentationQueue()
    /// 当前文档进度(0…1),供「文本即进度条」UI。
    var progress: Double { queue.currentScript?.progress ?? 0 }
    var currentTitle: String { queue.currentScript?.title ?? "" }

    private var hooks: Hooks?
    /// **演示窗口文本输入框 → 答疑路由**(2026-06-27):演示不再进自主模式抢麦,改用窗口里的输入框打字交互。
    /// 视图里输入框提交即调它,由 State 接到 `submitTextInput`(→ handlePresentationInputIfNeeded 答疑)。
    var onAsk: ((String) -> Void)?
    /// 答疑/手动打断请求:play 循环在**每拍之间**检查它,置位即停在当前拍(不丢位)。
    private var pauseRequested = false
    /// **彻底停止**请求(取消/退出):play 循环置位即终止,不再念下一拍(根治"取消后音频还在播")。
    private var stopRequested = false
    /// 标记一个在飞的播放任务,避免重复 play。
    private var playing = false
    /// 当前已显示的文档(避免续演同一篇时重复开窗、回到第0页)。
    private var shownDocumentPath: String?
    /// **当前讲解档**(详细/快速/概要)。用户中途切换 → 后续页按新档**懒重生成**讲稿(只重讲将念的页)。
    @Published private(set) var pace: LingShuPresentationPace = .detailed

    func install(_ hooks: Hooks) { self.hooks = hooks }

    /// 中途切换讲解档(语音"快速讲/概要过/详细讲"触发)。后续页 play 循环按新档懒重生成。
    func setPace(_ p: LingShuPresentationPace) {
        pace = p
        hooks?.note("讲解档切换", "后续按「\(p.label)」讲(后面的页会用这个深度重生成讲稿)。")
    }

    // MARK: - 1) 通读 + 生成脚本(预生成,演示中不再临时理解)

    /// 为一组文档建演示队列:逐篇通读、逐页生成讲稿。**这一步在演示开始前做完**,演示时只念脚本。
    func buildQueue(documentPaths: [String]) async {
        guard let hooks else { return }
        phase = .scripting
        hooks.note("生成演示脚本", "通读 \(documentPaths.count) 篇文档,逐页生成讲稿(演示中不再临时理解)。")
        var scripts: [LingShuPresentationScript] = []
        for path in documentPaths {
            let pages = await hooks.loadPages(path)
            guard !pages.isEmpty else {
                hooks.note("跳过", "无法读取或空文档:\((path as NSString).lastPathComponent)")
                continue
            }
            let title = (path as NSString).lastPathComponent
            // **并发逐页生成讲稿**(看图讲稿每页要给多模态脑发图、慢;串行 N 页要几分钟。先并发起所有页的 Task,各页网络 await 期间互不阻塞→总耗≈单页)。
            let tasks = pages.enumerated().map { (i, verbatim) in
                Task { @MainActor in await hooks.narrate(verbatim, i + 1, pages.count, title, self.pace) }
            }
            var beats: [LingShuPresentationBeat] = []
            for (i, verbatim) in pages.enumerated() {
                beats.append(.init(pageIndex: i, verbatim: verbatim, narration: await tasks[i].value, narrationPace: pace))
            }
            scripts.append(.init(documentPath: path, title: title, beats: beats))
        }
        queue = LingShuPresentationQueue(scripts: scripts)
        hooks.note("脚本就绪", "共 \(scripts.count) 篇、\(scripts.reduce(0) { $0 + $1.beatCount }) 页讲稿已生成,开始演示。")
    }

    // MARK: - 2) 照脚本念(play 循环;每拍之间可被答疑打断)

    /// 从当前文档的 playhead 开始照脚本念;念完一篇 → 停在 awaitingNextDoc 等用户确认切下一篇。
    /// `opening` 给了就在**首页画面就位后、念首页讲稿前**先念一次(开场白,如"好的我开始演示了")——
    /// 经 `announce` 钩子出声并 await 念完,**与首页讲稿串行同一发声通道**,杜绝开场白被首页 `speak` 的代次掐断
    /// (实测 bug:开场白只念到"演"字就被首页讲稿切掉)。续演/连播无开场白,默认 nil。
    func play(opening: String? = nil) async {
        guard let hooks, !playing else { return }
        playing = true
        defer { playing = false }
        pauseRequested = false
        stopRequested = false
        phase = .playing
        await hooks.setFullscreen(true)   // 续演(同一文档、无 showDocument)据此重进全屏;新文档由下面 open 后再进一次
        var pendingOpening = opening      // 开场白:首拍画面就位后念一次(只念一次)

        while var script = queue.currentScript {
            // 演这篇前先把它显示出来(多文档连播必需;同一篇续演不重复开窗),**open 之后再进全屏单页模式**——
            // 否则 open() 会把 slideshow 重置成连续滚动,goto 只滚动不翻页(实测 bug 2026-06-25)。
            if shownDocumentPath != script.documentPath {
                await hooks.showDocument(script.documentPath)
                await hooks.setFullscreen(true)
                shownDocumentPath = script.documentPath
            }
            // 念当前脚本剩余的拍。
            while let beat = script.currentBeat {
                if stopRequested || Task.isCancelled { phase = .finished; return }   // 取消/退出 → 彻底停,不再念
                if pauseRequested {
                    queue.updateCurrent(script)   // 回写播放头(不丢位)
                    phase = .pausedForQA
                    hooks.note("演示暂停", "第\(beat.pageNumber)页处停下,处理实时答疑;答完从此处或指定页继续。")
                    return
                }
                await hooks.navigate(beat.pageIndex)
                // **开场白(首拍·画面已就位)**:全屏 + 翻到第一页后,先把开场白念完,再念首页讲稿。
                // 放在 navigate 之后 = 画面已是第一页时开场,视觉不被开场白拖延;announce 内部 await 念完,
                // 下面首页 speak 自然排在它后面(同发声通道串行),不会半途掐断它。
                if let line = pendingOpening {
                    pendingOpening = nil
                    // **念确认句/开场白的同时,后台预合成本页讲稿**(仅当本页不需按新档重生成时):
                    // 跳页/开场进来的这页**从没被预取过**(预取流水线只提前合成 nextBeat),否则念完确认要现等云端首包 3-4s
                    // = 用户实测"翻页之后较长停顿"。announce 念这句的几秒里把本页首包合成好,念完即时起播本页讲稿,消停顿。
                    if beat.narrationPace == pace { hooks.prefetchNarration?(beat.narration) }
                    await hooks.announce?(line)
                    if stopRequested || Task.isCancelled { phase = .finished; return }
                }
                // **据当前讲解档懒重生成本页讲稿**(只在档不匹配时重讲——切档后从这页起按新深度讲)。
                var narration = beat.narration
                if beat.narrationPace != pace {
                    narration = await hooks.narrate(beat.verbatim, beat.pageNumber, script.beatCount, script.title, pace)
                    script.setCurrentNarration(narration, pace: pace)
                    queue.updateCurrent(script)
                }
                // **念当前页之前,先把下一页讲稿丢去后台预合成**——当前页念的几秒里下一页 TTS 就绪,
                // 翻到下一页即时起播,消除「翻页卡进处理中几秒」(仅当下一页不需按新档重生成时预取,否则文本会变、白取)。
                if let next = script.nextBeat, next.narrationPace == pace {
                    hooks.prefetchNarration?(next.narration)
                }
                await hooks.speak(narration)
                if stopRequested || Task.isCancelled { phase = .finished; return }   // speak 被掐后立刻停,不 advance/念下一拍
                if pauseRequested {   // **暂停发生在念这页途中 → 停在这页(不前进)**,继续时从这页接着念(根治"继续没从暂停位置开始")
                    queue.updateCurrent(script)
                    phase = .pausedForQA
                    hooks.note("演示暂停", "停在第\(beat.pageNumber)页;继续时从这页接着念。")
                    return
                }
                _ = script.advance()
                queue.updateCurrent(script)
                // 注:被答疑打断(requestPauseForQA 置 pauseRequested)→ 顶部 pauseRequested 检查会在翻一页后暂停,
                // 不再狂翻到底(根治"打断后一路翻到最后一页";真正的修复在 PrimarySurfaces 手动接管→requestPauseForQA)。
            }
            // 这一篇念完了。
            if queue.hasNext {
                phase = .awaitingNextDoc
                let (cur, total) = queue.position
                hooks.note("一篇演完", "「\(script.title)」演示完毕(\(cur)/\(total) 篇);等你确认后切下一篇。")
                // **出声告诉用户**(否则篇间静默,用户不知道要说「继续」=串行演示像卡住了)。
                await hooks.announce?("这一篇就讲到这儿,\(total) 篇里的第 \(cur) 篇。你说「继续」我接着演下一篇。")
                return
            } else {
                await hooks.announce?("好,演示就到这儿,全部讲完了。还有想细看的随时跟我说。")   // 出声收尾(别静默退场)
                phase = .finished
                await hooks.setFullscreen(false)
                hooks.note("全部演完", "演示队列全部完成。")
                return
            }
        }
        phase = .finished
    }

    // MARK: - 3) 答疑暂停 / 视频流式续演

    /// 实时提问打断:请求在下一拍间隙暂停(主线程随后处理答疑),并**立刻掐当前 TTS**(像视频暂停就静音,别等本页念完)。
    func requestPauseForQA() {
        guard phase == .playing else { return }
        pauseRequested = true
        hooks?.interruptAudio()
    }

    /// **同步彻底停止**(供 cancelCurrentCall / abortActiveFlow / 退出演示等同步取消路径调):
    /// 掐音频 + 立即退出 active 态 + 置停止位 → play 循环在 speak 返回后随即终止,不再念下一拍。
    /// 这里必须同步置 finished,否则下一条普通输入会在旧 play 任务收尾前继续被演示链路截获。
    func requestStop() {
        stopRequested = true
        phase = .finished
        hooks?.interruptAudio()
        shownDocumentPath = nil
    }

    /// 答疑结束后继续:`seekTo` 给了就先拖到那页(视频流式),否则从当前位置续。
    /// `opening` 给了(如"好,翻到第N页。"/"好,接着讲。")就由 play **先翻到该页(画面即时响应)、再串行念这句确认、再念讲稿**——
    /// 经 announce 钩子(抑制气泡自动朗读)出声,杜绝确认句与续演首页讲稿抢发声通道把讲稿掐掉(实测:跳页后那页没念就被跳过)。
    func resume(seekTo pageIndex: Int? = nil, opening: String? = nil) async {
        guard phase == .pausedForQA, var script = queue.currentScript else { return }
        if let pageIndex {
            // 把"页号"换算成对应 beat 下标(beat.pageIndex == 目标页)。
            if let beatIdx = script.beats.firstIndex(where: { $0.pageIndex == pageIndex }) {
                script.seek(to: beatIdx)
            } else {
                script.seek(to: pageIndex)
            }
            queue.updateCurrent(script)
        }
        await play(opening: opening)
    }

    /// 演示中/暂停时拖动进度条到任意位置(不自动续播,交给调用方决定续不续)。
    func seek(to beatIndex: Int) {
        guard var script = queue.currentScript else { return }
        script.seek(to: beatIndex)
        queue.updateCurrent(script)
    }

    /// **视频流式拖动续演**(UI 点/拖进度条用):播放中→暂停→跳到该拍→从那继续;暂停中→跳到该拍待续。
    /// 用"暂停再跳"而非播放中直改,避免在飞的 play 循环用的是脚本值拷贝、跳了不生效。
    func seekAndContinue(toBeat index: Int) async {
        let wasPlaying = (phase == .playing)
        if wasPlaying {
            requestPauseForQA()
            for _ in 0..<300 where phase == .playing { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        seek(to: index)
        if wasPlaying || phase == .pausedForQA { await play() }
    }

    // MARK: - 4) 多文档连播:用户确认后切下一篇

    /// 用户确认 → 切到下一篇并继续演;无下一篇 → finished。
    /// `opening`(如"好,继续下一篇。")由 play 先显示下一篇首页、再串行念这句、再念讲稿(同 resume 口径,杜绝抢通道)。
    func confirmAndPlayNext(opening: String? = nil) async {
        guard phase == .awaitingNextDoc else { return }
        if queue.advanceToNext() != nil {
            await play(opening: opening)
        } else {
            phase = .finished
            await hooks?.setFullscreen(false)
        }
    }

    /// 整体收尾(用户喊停/关窗):掐音频 + 彻底停 + 退全屏。
    func stop() async {
        stopRequested = true
        hooks?.interruptAudio()
        phase = .finished
        shownDocumentPath = nil
        await hooks?.setFullscreen(false)
    }

    var isActive: Bool { phase == .playing || phase == .pausedForQA || phase == .scripting || phase == .awaitingNextDoc }
}
