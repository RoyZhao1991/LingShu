import AppKit

/// 轻量提示音(非语音):用于"进入聆听/唤醒"等状态切换的清脆反馈。
/// 复用系统自带清脆音,不需打包音频资源;取不到就静默(不报错、不打断)。
enum LingShuCueSound {
    /// 唤醒提示音:叫了「灵枢」进入聆听阶段时响一声。清脆、短、不大声(默认音量 0.4)。
    @MainActor
    static func playWakeChime(volume: Float = 0.4) {
        // "Glass" 是清脆的单音铃;取不到回落 Tink/Pop(都在 /System/Library/Sounds)。
        guard let sound = NSSound(named: "Glass") ?? NSSound(named: "Tink") ?? NSSound(named: "Pop") else { return }
        sound.volume = volume
        sound.stop()   // 若上一声还在播,先停再重放,确保每次叫都清脆响一下
        sound.play()
    }

    /// 受令提示音:语音指令**收口提交、进入处理中**时响一声——让主人听到"听到了,在处理了"。
    /// 用与唤醒音(Glass)**不同**的音色("Tink/Pop")以便区分:Glass=我在听,Tink=收到在办。
    @MainActor
    static func playAcknowledgeChime(volume: Float = 0.35) {
        guard let sound = NSSound(named: "Tink") ?? NSSound(named: "Pop") ?? NSSound(named: "Morse") else { return }
        sound.volume = volume
        sound.stop()
        sound.play()
    }

    // MARK: - 执行中忙音(轻微"嘟…嘟…",告诉主人"在处理、没死";朗读/空闲即停,不和 TTS 打架)

    @MainActor private static var lastBusyBeepAt = Date.distantPast
    @MainActor private static var busyActive = false
    /// 忙音脉冲序号:每响一声"嘟"+1。本体(数字人 snapshot)据它在处理中于几种颜色间切换,与忙音同频(让等待不无聊)。
    /// 本体在 TimelineView 里每帧读它,故无需 @Published——切了下一帧就跟上。
    @MainActor private(set) static var busyPulseIndex = 0

    /// 忙音一拍:**由"后台安全"的驱动(自主感知 1s 自驱 Task / 前台 coreTimer)在「处理中且不在朗读」时每秒调一次**,
    /// 内部按 `intervalSeconds` 节流真正响一声很轻的低"嘟"。**不自己持有 Timer**——独立 Timer 在 App Nap/窗口遮挡时会被系统
    /// 节流(实测:自主/在岗时 UI coreTimer 与独立 Timer 都靠不住),改由那条已抑制 App Nap 的自驱循环驱动才可靠。
    /// 用低音"Submarine/Purr"(柔和、适合循环);被 AEC 抵消故不会自触发语音识别。进入处理立即先响一声(first)。
    @MainActor
    static func busyTick(intervalSeconds: TimeInterval = 2.4, volume: Float = 0.28) {
        let now = Date()
        let first = !busyActive
        busyActive = true
        guard first || now.timeIntervalSince(lastBusyBeepAt) >= intervalSeconds else { return }
        lastBusyBeepAt = now
        busyPulseIndex += 1   // 每响一声切一次本体颜色(与忙音同频)
        guard let s = NSSound(named: "Submarine") ?? NSSound(named: "Purr") ?? NSSound(named: "Tink") else {
            if first { lingShuControlLog("busy-tone: 无可用系统音,忙音未响") }
            return
        }
        s.volume = volume
        s.stop()
        let ok = s.play()
        if first { lingShuControlLog("busy-tone: 起忙音 sound=\(s.name ?? "?") vol=\(volume) play=\(ok)") }
    }

    /// 离开处理中(空闲/开始朗读)时调:复位,下次进入处理立即先响一声。幂等。
    @MainActor
    static func busyStop() { busyActive = false }
}
