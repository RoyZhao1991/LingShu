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
        /// 据一页正文生成该页讲稿(控制面 LLM 一次性,预生成)。
        var narrate: @MainActor (_ verbatim: String, _ pageNumber: Int, _ total: Int, _ title: String) async -> String
        /// 把预览翻到某页(0-based)。
        var navigate: @MainActor (_ pageIndex: Int) async -> Void
        /// 念一段讲稿(**阻塞到念完**,这样答疑能在两拍之间插入)。
        var speak: @MainActor (_ text: String) async -> Void
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
    /// 答疑/手动打断请求:play 循环在**每拍之间**检查它,置位即停在当前拍(不丢位)。
    private var pauseRequested = false
    /// **彻底停止**请求(取消/退出):play 循环置位即终止,不再念下一拍(根治"取消后音频还在播")。
    private var stopRequested = false
    /// 标记一个在飞的播放任务,避免重复 play。
    private var playing = false
    /// 当前已显示的文档(避免续演同一篇时重复开窗、回到第0页)。
    private var shownDocumentPath: String?

    func install(_ hooks: Hooks) { self.hooks = hooks }

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
            var beats: [LingShuPresentationBeat] = []
            for (i, verbatim) in pages.enumerated() {
                let narration = await hooks.narrate(verbatim, i + 1, pages.count, title)
                beats.append(.init(pageIndex: i, verbatim: verbatim, narration: narration))
            }
            scripts.append(.init(documentPath: path, title: title, beats: beats))
        }
        queue = LingShuPresentationQueue(scripts: scripts)
        hooks.note("脚本就绪", "共 \(scripts.count) 篇、\(scripts.reduce(0) { $0 + $1.beatCount }) 页讲稿已生成,开始演示。")
    }

    // MARK: - 2) 照脚本念(play 循环;每拍之间可被答疑打断)

    /// 从当前文档的 playhead 开始照脚本念;念完一篇 → 停在 awaitingNextDoc 等用户确认切下一篇。
    func play() async {
        guard let hooks, !playing else { return }
        playing = true
        defer { playing = false }
        pauseRequested = false
        stopRequested = false
        phase = .playing
        await hooks.setFullscreen(true)   // 续演(同一文档、无 showDocument)据此重进全屏;新文档由下面 open 后再进一次

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
                await hooks.speak(beat.narration)
                if stopRequested || Task.isCancelled { phase = .finished; return }   // speak 被掐后立刻停,不 advance/念下一拍
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
                return
            } else {
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
    /// 掐音频 + 置停止位 → play 循环在 speak 返回后随即终止,不再念下一拍。根治"取消后音频还在播"。
    func requestStop() {
        stopRequested = true
        hooks?.interruptAudio()
        shownDocumentPath = nil
    }

    /// 答疑结束后继续:`seekTo` 给了就先拖到那页(视频流式),否则从当前位置续。
    func resume(seekTo pageIndex: Int? = nil) async {
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
        await play()
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
    func confirmAndPlayNext() async {
        guard phase == .awaitingNextDoc else { return }
        if queue.advanceToNext() != nil {
            await play()
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
