import Foundation

/// 声线寻址闸门：一句话收口后、提交中枢前的最终裁决——这句话是"主人在对灵枢说"，
/// 还是环境里的旁人交谈/噪声。以绑定的主人声线为最高优先：
/// 1. 身份锁开启时，声线不匹配主人 → 一律按环境音忽略（点名也不放行，防旁人冒用）；
/// 2. 点名灵枢（唤醒词）→ 响应；
/// 3. 多人对话环境且未点名 → 只有处于近期对话延续窗口内才响应，否则判定为人际交谈不插话；
/// 4. 单人环境 → 通话模式/对话窗口内/显式开启的听写默认都是对灵枢说话。
/// 纯函数，便于测试与替换（可插拔）。
struct LingShuVoiceAddressingGate {
    struct Inputs {
        var transcript: String
        var containsWakeWord: Bool
        var lockEnabled: Bool
        /// 身份服务最近的声线匹配度（0~1）；锁未开启或尚无样本时为 nil。
        var ownerVoiceConfidence: Double?
        var ownerVoiceThreshold: Double = 0.55
        /// 声线画像检测到的多说话人迹象（基频分布双簇）。
        var multipleSpeakersDetected: Bool
        /// 距上一条对话消息的秒数；nil 表示还没有任何交流。
        var secondsSinceLastExchange: TimeInterval?
        var engagementWindow: TimeInterval = 45
        /// 极简通话模式 = 用户显式拨给灵枢的电话。
        var isExplicitCallMode: Bool
    }

    enum Verdict: Equatable {
        case respond(reason: String)
        case ignore(reason: String)
    }

    static func decide(_ inputs: Inputs) -> Verdict {
        // ① 主人声线优先：身份锁开启时逐句核验，不匹配即环境音。
        if inputs.lockEnabled {
            let confidence = inputs.ownerVoiceConfidence ?? 0
            guard confidence >= inputs.ownerVoiceThreshold else {
                return .ignore(reason: String(
                    format: "声线与主人档案不匹配（匹配度 %.0f%%，门槛 %.0f%%），按环境音忽略",
                    confidence * 100, inputs.ownerVoiceThreshold * 100
                ))
            }
        }

        // ② 点名灵枢：明确寻址，直接响应。
        if inputs.containsWakeWord {
            return .respond(reason: "点名灵枢")
        }

        let engaged = inputs.secondsSinceLastExchange.map { $0 <= inputs.engagementWindow } ?? false

        // ③ 多人环境：未点名时只认对话延续，否则判定为人际交谈。
        if inputs.multipleSpeakersDetected {
            return engaged
                ? .respond(reason: "多人环境，但处于对话延续窗口内")
                : .ignore(reason: "检测到多人对话且未点名灵枢，判定为人际交谈，不插话")
        }

        // ④ 单人环境：显式通话/对话延续/显式开启的听写都默认在对灵枢说话。
        if inputs.isExplicitCallMode {
            return .respond(reason: "通话模式")
        }
        if engaged {
            return .respond(reason: "对话延续窗口内")
        }
        return .respond(reason: "单人环境实时对话")
    }
}

/// 自适应 VAD 阈值：跟踪环境噪声底（仅在未捕获语音时学习），
/// 嘈杂环境自动抬高说话/收口门槛，屏蔽底噪对断句的干扰。
struct LingShuAdaptiveVAD: Equatable {
    private(set) var noiseFloor: Float = 0.02
    private let baseSpeak: Float = 0.12
    private let baseSilence: Float = 0.06

    /// 说话判定阈值：至少高于噪声底一段安全余量。
    var speakThreshold: Float {
        max(baseSpeak, min(0.5, noiseFloor * 2.2 + 0.02))
    }

    /// 静音收口阈值：随噪声底抬升，避免底噪让一句话永远"收不了口"。
    var silenceThreshold: Float {
        max(baseSilence, min(speakThreshold - 0.01, noiseFloor * 1.6 + 0.01))
    }

    /// 打断阈值：比说话阈值更高，避免回声/底噪误打断播报。
    var bargeInThreshold: Float {
        max(0.2, speakThreshold * 1.6)
    }

    /// 只在"没有人在说话"的时刻学习噪声底（指数滑动平均，慢升快降）。
    mutating func observe(level: Float, isCapturingSpeech: Bool) {
        guard !isCapturingSpeech, level < speakThreshold else { return }
        if level < noiseFloor {
            noiseFloor = noiseFloor * 0.8 + level * 0.2
        } else {
            noiseFloor = noiseFloor * 0.95 + level * 0.05
        }
        noiseFloor = min(noiseFloor, 0.2)
    }
}
