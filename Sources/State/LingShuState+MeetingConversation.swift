import Foundation

/// 会议端到端对话的接线层:把 `LingShuMeetingConversationController` 接上 state + 注入的语音管理器。
/// 入口:UI(会议按钮)/ MCP(`meeting_converse_start`/`meeting_converse_stop`)。
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
}
