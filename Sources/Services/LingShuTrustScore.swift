import Foundation

/// 系统就绪度 / 置信度(顶栏 TRUST)的**纯逻辑**(可单测)。
/// 把"通道是否就绪"和"分数怎么合成"从 @MainActor 状态里抽出来,既可单测、也根治了
/// 「ASR 永远用写死的 `asr:datanet` 键判,本地 ASR(默认)永远不被计入 → 通道恒 3/4 → 分数钉在 91%」的 bug。
enum LingShuTrustScore {

    /// 四能力通道(脑/眼/耳/口)就绪度。**本机兜底通道(本地 ASR/TTS)始终可用 = 就绪**,
    /// 不再依赖某个写死的云端通道键去判(那正是把耳朵漏算、分数钉死的根因)。
    static func channelReadiness(
        brainValidated: Bool,
        visionValidated: Bool,
        asrLocalMode: Bool, asrCloudValidated: Bool,
        ttsLocalMode: Bool, ttsActiveValidated: Bool
    ) -> (ready: Int, total: Int) {
        var ready = 0
        if brainValidated { ready += 1 }                       // 脑(中枢文本)
        if visionValidated { ready += 1 }                      // 眼(视觉)
        if asrLocalMode || asrCloudValidated { ready += 1 }    // 耳(听):本地 SFSpeech 始终可用,否则看云端 ASR 校验
        if ttsLocalMode || ttsActiveValidated { ready += 1 }   // 口(说):本地系统语音始终可用,否则看当前 TTS 通道校验
        return (ready, 4)
    }

    /// 就绪度分(0–100):连通 0.40 / 通道就绪比 0.35 / 近期验收通过率 0.25。
    /// **无数据的维度自动从权重里剔除**——不凭空拉高也不无故压低。
    static func score(
        modelConnected: Bool,
        channelsReady: Int, channelsTotal: Int,
        tasksPassed: Int, tasksFinished: Int
    ) -> Int {
        var weighted = 0.0, total = 0.0
        weighted += (modelConnected ? 1.0 : 0.0) * 0.40; total += 0.40
        if channelsTotal > 0 {
            weighted += Double(channelsReady) / Double(channelsTotal) * 0.35; total += 0.35
        }
        if tasksFinished > 0 {
            weighted += Double(tasksPassed) / Double(tasksFinished) * 0.25; total += 0.25
        }
        guard total > 0 else { return 0 }
        return Int((weighted / total * 100).rounded())
    }
}
