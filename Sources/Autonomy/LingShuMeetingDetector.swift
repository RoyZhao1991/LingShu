import Foundation

/// 会议纪要 · 纯逻辑(可单测,无 UI/系统依赖)。
///
/// 两块纯逻辑:
/// 1. **会议检测(反射,机械可判)**:据前台 app bundle + 窗口标题 + 系统声音活动,判断"进入/离开会议"。
///    这是允许机械化的"反射",不是替大脑决策——大脑只在会议结束拿到转写后做纪要。
/// 2. **转写分段累积**:长会议要靠"分段轮转"绕开单次 ASR 会话时长上限(append 本身不阻塞、识别器自有队列,
///    所以不会丢音;真正的限制是单会话时长)。这里只放纯数据结构 + 拼装,定时轮转由 State 侧驱动。

/// 一段会议转写(一次轮转的产物)。
struct LingShuMeetingMinuteSegment: Equatable, Sendable {
    let at: Date
    let text: String
}

/// 会议检测的滚动状态(纯值,State 持有一份)。
struct LingShuMeetingDetectionState: Equatable, Sendable {
    var inMeeting = false
    var enteredAt: Date?
    var lastSignalAt: Date?
}

enum LingShuMeetingDetector {
    /// 原生会议 app 的 bundle 关键词(命中即视为会议 app 在前台)。
    static let bundleHints = [
        "zoom", "teams", "webex", "tencent", "wemeet", "voov", "feishu", "lark",
        "dingtalk", "facetime", "skype", "discord", "gotomeeting", "bluejeans", "whereby"
    ]
    /// 窗口标题里的会议关键词(抓浏览器内会议如 Google Meet,标题里常带"Meet/会议/通话")。
    static let titleHints = [
        "会议", "meeting", "zoom", "google meet", "meet.google", "teams", "webex",
        "通话", "正在通话", "视频通话", "腾讯会议", "飞书会议", "video call", " call"
    ]

    static func looksLikeMeetingApp(_ bundle: String?) -> Bool {
        guard let b = bundle?.lowercased() else { return false }
        return bundleHints.contains { b.contains($0) }
    }

    static func titleLooksLikeMeeting(_ signature: String?) -> Bool {
        guard let s = signature?.lowercased() else { return false }
        return titleHints.contains { s.contains($0) }
    }

    enum Transition: Equatable, Sendable { case none, entered, exited }

    /// 推进检测状态机,返回是否发生进入/离开会议的跃迁。
    /// - 进入:前台是会议 app 或窗口标题像会议(且最好有声音,但不强制——有人只听)。
    /// - 离开:已在会议中,且"会议信号"(会议 app/标题/声音)连续消失超过 `exitGrace`(默认 60s,
    ///   容忍中途切去记笔记/查资料)。
    static func update(
        _ state: inout LingShuMeetingDetectionState,
        frontmostBundle: String?,
        windowSignature: String?,
        audioActive: Bool,
        now: Date = Date(),
        exitGrace: TimeInterval = 60
    ) -> Transition {
        let meetingSurface = looksLikeMeetingApp(frontmostBundle) || titleLooksLikeMeeting(windowSignature)
        // 会议信号:会议界面在前台,或(已在会议中且仍有声音=切走但会议还在响)。
        let signalPresent = meetingSurface || (state.inMeeting && audioActive)
        if signalPresent { state.lastSignalAt = now }

        if !state.inMeeting {
            guard meetingSurface else { return .none }
            state.inMeeting = true
            state.enteredAt = now
            state.lastSignalAt = now
            return .entered
        } else {
            if let last = state.lastSignalAt, now.timeIntervalSince(last) > exitGrace {
                state.inMeeting = false
                state.enteredAt = nil
                return .exited
            }
            return .none
        }
    }

    /// 把分段拼成给大脑的完整转写(带相对时间戳,便于纪要分时段)。
    static func assembleTranscript(_ segments: [LingShuMeetingMinuteSegment], start: Date?) -> String {
        guard !segments.isEmpty else { return "" }
        let base = start ?? segments.first!.at
        return segments.map { seg in
            let mins = Int(seg.at.timeIntervalSince(base) / 60)
            return "[\(mins)分] \(seg.text)"
        }.joined(separator: "\n")
    }
}
