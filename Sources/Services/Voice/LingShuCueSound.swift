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
}
