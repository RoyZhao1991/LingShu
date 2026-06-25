import Foundation

/// 「演示与答疑」插件的纯逻辑核心(可单测、0 模型依赖):演示脚本 + 播放头(进度) + 多文档队列。
///
/// 设计取向(用户定调 2026-06-25):
/// - **先通读→生成脚本→照脚本念**:演示前把每页讲稿一次生成好(beat.narration),演示中只念脚本,
///   绝不临时理解文档(避免频繁卡顿、演示效果变差)。
/// - **文本即进度条**:脚本是 beat 序列,playhead 就是进度。`progress` 给 UI 画进度条;`seek` 拖到任意位置。
/// - **视频流式续演**:答疑打断后,可从**当前位置**或**指定位置**继续(`seek` + 继续念),像视频拖动。
/// - **多文档连播**:`LingShuPresentationQueue` 是文档队列,一篇演完→用户确认→切下一篇(像多视频连播)。
/// - **通用**:任何文档(PPT/PDF/Word/HTML…)都走这套,不是 PPT 定制。

/// 讲解档(像视频倍速,但调的是**讲解深度**):用户可中途语音切换,后续页按新档重生成讲稿。
enum LingShuPresentationPace: String, Codable, Sendable, Equatable, CaseIterable {
    case detailed   // 详细(默认):约60-160字,展开讲清
    case brief      // 快速:约30-50字,只抓核心、跳细节
    case overview   // 概要:约15-25字,一句话带过主旨

    var label: String { switch self { case .detailed: "详细"; case .brief: "快速"; case .overview: "概要" } }
    /// 喂给讲稿生成器的深度要求。
    var narrationGuidance: String {
        switch self {
        case .detailed: return "约60-160字,自然展开、把这页讲清楚"
        case .brief:    return "约30-50字,只讲这页的核心要点、跳过细节,语气利落"
        case .overview: return "约15-25字,一句话带过这页主旨即可,快速过"
        }
    }
}

/// 一个演示节拍 = 一页:该页真实内容 + 预生成讲稿。念 narration,verbatim 用于防漂移/答疑取证。
struct LingShuPresentationBeat: Codable, Sendable, Equatable {
    let pageIndex: Int        // 0-based,对应预览页索引
    let verbatim: String      // 该页真实文字(从 PDF/正文抽,权威,防大模型凭记忆瞎讲)
    var narration: String     // 当前讲稿(演示时念这个)
    var narrationPace: LingShuPresentationPace   // 当前讲稿是按哪个档生成的(懒重生成:档不匹配才重讲)

    var pageNumber: Int { pageIndex + 1 }   // 1-based 显示页号

    init(pageIndex: Int, verbatim: String, narration: String, narrationPace: LingShuPresentationPace = .detailed) {
        self.pageIndex = pageIndex
        self.verbatim = verbatim
        self.narration = narration
        self.narrationPace = narrationPace
    }
}

/// 一篇文档的演示脚本 + 播放头。playhead = 当前念到第几拍(0-based);文本序列本身即进度条。
struct LingShuPresentationScript: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let documentPath: String
    let title: String
    var beats: [LingShuPresentationBeat]
    /// 当前播放头(0-based)。等于 beats.count 表示已念完。
    private(set) var playhead: Int

    var beatCount: Int { beats.count }
    var isComplete: Bool { playhead >= beats.count }
    var currentBeat: LingShuPresentationBeat? { beats.indices.contains(playhead) ? beats[playhead] : nil }

    /// 进度(0…1),供「文本即进度条」渲染。空脚本视为已完成=1。
    var progress: Double {
        guard !beats.isEmpty else { return 1 }
        return min(1, Double(playhead) / Double(beats.count))
    }

    init(id: String = "pres-\(UUID().uuidString.prefix(8))", documentPath: String, title: String,
         beats: [LingShuPresentationBeat], playhead: Int = 0) {
        self.id = id
        self.documentPath = documentPath
        self.title = title
        self.beats = beats
        self.playhead = max(0, min(playhead, beats.count))
    }

    /// **视频流式 seek**:拖到任意位置(夹紧到合法范围)。返回定位到的 beat。用于「从指定位置继续」。
    @discardableResult
    mutating func seek(to index: Int) -> LingShuPresentationBeat? {
        guard !beats.isEmpty else { playhead = 0; return nil }
        playhead = max(0, min(index, beats.count - 1))
        return currentBeat
    }

    /// 念完当前一拍 → 前进。返回下一拍(返回 nil 表示这篇演完了)。
    @discardableResult
    mutating func advance() -> LingShuPresentationBeat? {
        guard playhead < beats.count else { return nil }
        playhead += 1
        return currentBeat
    }

    /// 把某页的讲稿写回(脚本生成阶段逐页填)。页不存在则忽略。
    mutating func setNarration(_ text: String, forPageIndex pageIndex: Int) {
        guard let i = beats.firstIndex(where: { $0.pageIndex == pageIndex }) else { return }
        beats[i].narration = text
    }

    /// 把**当前播放头那页**的讲稿换成按某档重生成的版本(懒重生成用)。
    mutating func setCurrentNarration(_ text: String, pace: LingShuPresentationPace) {
        guard beats.indices.contains(playhead) else { return }
        beats[playhead].narration = text
        beats[playhead].narrationPace = pace
    }
}

/// 多文档连续演示队列(类似多视频连播):一篇演完→用户确认→切下一篇。本质是个队列。
struct LingShuPresentationQueue: Codable, Sendable, Equatable {
    var scripts: [LingShuPresentationScript]
    private(set) var currentIndex: Int

    init(scripts: [LingShuPresentationScript] = [], currentIndex: Int = 0) {
        self.scripts = scripts
        self.currentIndex = scripts.isEmpty ? 0 : max(0, min(currentIndex, scripts.count - 1))
    }

    var currentScript: LingShuPresentationScript? { scripts.indices.contains(currentIndex) ? scripts[currentIndex] : nil }
    var hasNext: Bool { currentIndex + 1 < scripts.count }
    var count: Int { scripts.count }
    /// 当前是第几篇 / 共几篇(供「3 篇里的第 2 篇」提示)。
    var position: (current: Int, total: Int) { (currentIndex + 1, scripts.count) }

    /// 切到下一篇(用户确认后调)。返回新的当前脚本;已是最后一篇 → nil。
    @discardableResult
    mutating func advanceToNext() -> LingShuPresentationScript? {
        guard hasNext else { return nil }
        currentIndex += 1
        return currentScript
    }

    /// 把对当前脚本的改动(playhead 等)写回队列(值类型,需回写)。
    mutating func updateCurrent(_ script: LingShuPresentationScript) {
        guard scripts.indices.contains(currentIndex) else { return }
        scripts[currentIndex] = script
    }
}

/// 演示会话相位:闲置 / 生成脚本中 / 播放中 / 因答疑暂停 / 等用户确认切下一篇 / 全部结束。
/// 关键:**答疑(交互)走主线程线性**——pausedForQA 时主线程处理问答,答完 seek 回继续。
enum LingShuPresentationPhase: String, Codable, Sendable, Equatable {
    case idle
    case scripting        // 通读 + 逐页生成讲稿中
    case playing          // 照脚本念
    case pausedForQA      // 被实时提问打断,主线程处理答疑
    case awaitingNextDoc  // 当前文档演完,等用户确认切下一篇
    case finished         // 队列全部演完
}
