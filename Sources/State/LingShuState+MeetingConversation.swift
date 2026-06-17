import Foundation

/// 会议端到端对话的接线层:把 `LingShuMeetingConversationController` 接上 state + 注入的语音管理器。
/// 入口:**MCP**(`meeting_converse_start`/`meeting_converse_stop`)——目前**没有 UI 按钮**。
/// 另:在岗(独立运行)会**自动**起「听系统声音」的纯听半边(系统音频→ASR→感知链 ambient 通道,
/// 不走这里的虚拟麦应答闭环),见 `startStandingAmbientListening`。
@MainActor
extension LingShuState {

    var isMeetingConversationActive: Bool { meetingConversation.isActive }

    /// 开始会议对话:听会议(系统音频)→ 灵枢应答经 TTS(配虚拟麦后回到会议)。需屏幕录制权限。
    @discardableResult
    func startMeetingConversation() -> String {
        guard let voice = voiceManager else {
            return "语音管理器未就绪(UI 尚未注入),无法开始会议对话。"
        }
        guard !meetingConversation.isActive else { return "会议对话已在进行中。" }
        // 虚拟麦是灵枢的内置能力:没装(或已装但签名/内容与随包驱动不一致,如 Apple Development→Developer ID 升级)
        // 就自安装(一次系统授权,不需用户手动跑脚本)。**总是交给 installIfNeeded 自己判**——别在这里用 isInstalled()
        // 短路,否则残留的旧签名驱动永远不会被升级(coreaudiod 拒载旧的→设备永不出现)。在后台跑(会弹授权框)。
        appendTrace(kind: .runtime, actor: "会议", title: "自安装/校验虚拟麦克风", detail: "首次或升级:请在弹出的系统授权框允许,装好后即为常驻能力。")
        Task.detached {
            let r = LingShuAudioDriverInstaller.installIfNeeded()
            await MainActor.run { [weak self] in
                self?.appendTrace(kind: r == .installed || r == .alreadyInstalled ? .result : .warning,
                                  actor: "会议", title: "虚拟麦克风安装", detail: "\(r)")
                _ = LingShuAudioRouting.selectOutputDevice(named: "灵枢虚拟麦")
            }
        }
        // 尝试把 TTS 定向到灵枢虚拟麦克风(装了才有);没装则回落系统默认输出(本机闭环仍可验证)。
        let routed = LingShuAudioRouting.selectOutputDevice(named: "灵枢虚拟麦")
        meetingConversation.start(state: self, voice: voice)
        voiceOutputEnabled = true   // 会议里必须出声
        appendTrace(kind: .runtime, actor: "会议", title: "开始会议对话",
                    detail: "系统音频→ASR→应答→TTS;输出路由\(routed ? "已定向灵枢虚拟麦克风" : "走系统默认(未检测到虚拟麦,先装 HAL 驱动)")")
        missionStatus = "会议对话中:听对方发言并应答。"
        return routed
            ? "已开始会议对话:我在听会议里的发言并自动应答,声音经灵枢虚拟麦克风。把会议 App 的麦克风也选成灵枢虚拟麦克风即可。"
            : "已开始会议对话(本机闭环):我在听会议发言并应答。但还没检测到『灵枢虚拟麦克风』——先 build+install HAL 驱动(Drivers/LingShuAudioDriver),对方才能听见我。"
    }

    @discardableResult
    func stopMeetingConversation() -> String {
        guard meetingConversation.isActive else { return "当前没有进行中的会议对话。" }
        meetingConversation.stop()
        appendTrace(kind: .runtime, actor: "会议", title: "结束会议对话", detail: "已停止系统音频采集与应答")
        missionStatus = "会议对话已结束。"
        return "已结束会议对话。"
    }

    /// 演示/会议进行中,把对方的**现场提问**注入「当前正在跑的那条脑回路」(自主演示会话优先,否则主会话):
    /// 复用会话的回合/步骤边界注入机制(`injectCorrection` 这条底层注入,但语义是"提问"非"纠正")——
    /// 大脑在下一步边界看到问题 → 先口头作答 → 接着汇报。**同一个大脑边讲边答,不另起独立汇报人。**
    /// 与 `interjectCorrection` 区别:不做"纠正"措辞、不进 dreaming 设计反馈、只注入正在跑的那条会话(不双投)。
    func injectMeetingQuestion(_ utterance: String) {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let target = autonomousSessionHolder ?? mainAgentSessionHolder else { return }
        let recordID = autonomousRunRecordID ?? currentAgentTurnRecordID
        appendTaskRecordMessage(recordID, actor: "现场", role: "提问", kind: .user, text: trimmed)
        appendTrace(kind: .system, actor: "会议", title: "现场提问", detail: trimmed)
        missionStatus = "收到现场提问,正在作答…"
        let framed = "[现场提问] \(trimmed)\n\n先简要口头回答这个问题(用 speak),再接着汇报。"
        Task { await target.injectCorrection(framed) }
    }
}
