import SwiftUI

/// 语音交互状态机（用户定调 2026-06-18）。一个明确闭环：
///
///   待机 → 我在听 → 处理中 → 回应中 → 待机
///
/// 唯一变体：**处理中 / 回应中**时被**唤醒词打断** → 回到**我在听**；**我在听**窗口内没识别到有效内容 → 回退**待机**。
///
/// `derive` 是纯函数（可单测）：状态完全由「音频是否真在播 / 模型或 TTS 是否在忙 / 是否处于聆听窗口」推出，
/// 不依赖任何视图或副作用。优先级（高→低）：回应中 > 处理中 > 我在听 > 待机——
/// 这样"被唤醒词打断"会先掐掉 TTS（音频停→回应中/处理中 false）、同时开聆听窗口，自然落到「我在听」。
enum LingShuVoicePhase: String, Equatable {
    case standby      // 待机中
    case listening    // 我在听
    case processing   // 处理中
    case responding   // 回应中

    static func derive(
        audiblePlaying: Bool,          // TTS 音频**真正在播**（输出电平起来了）
        modelOrLoopBusy: Bool,         // 模型在跑 / LOOP 相位在跑
        ttsQueuedOrPending: Bool,      // TTS 已请求、排队中或还没起播
        listeningArmed: Bool,          // 处于「我在听」聆听窗口（喊唤醒词/开口触发）
        secondsSinceVoiceActivity: TimeInterval,
        listeningWindow: TimeInterval  // 聆听窗口时长；超时无有效内容即回待机
    ) -> LingShuVoicePhase {
        if audiblePlaying { return .responding }
        if modelOrLoopBusy || ttsQueuedOrPending { return .processing }
        if listeningArmed, secondsSinceVoiceActivity < listeningWindow { return .listening }
        return .standby
    }

    var caption: String {
        switch self {
        case .standby:    "待机中"
        case .listening:  "我在听"
        case .processing: "处理中"
        case .responding: "回应中"
        }
    }

    var tint: Color {
        switch self {
        case .standby:    Color.lingFg.opacity(0.55)
        case .listening:  .green
        case .processing: .cyan
        case .responding: .green
        }
    }

    var icon: String {
        switch self {
        case .standby:    "moon.zzz"
        case .listening:  "ear.fill"
        case .processing: "brain"
        case .responding: "speaker.wave.2.fill"
        }
    }
}
