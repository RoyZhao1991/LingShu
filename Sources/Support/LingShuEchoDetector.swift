import Foundation

/// 自激回声判定(纯函数):一句麦克风转写是不是灵枢自己刚说出口的话的回声。
///
/// 场景:发声时麦克风拾到自己的 TTS(AEC 不彻底时),回声在说完后才"静音收口"提交成输入 → 灵枢把自己
/// 的话当指令、疯狂自激循环(实测:它说"好的,请说"→麦收到"好的"→又回它…)。busy 闸门只挡发声当下 +
/// 短冷却,延迟收口的回声会漏。这里用**内容比对**兜底:听到的若是灵枢最近说过的话(或其片段)→ 判回声丢弃。
/// 仅在"刚说完不久"的窗口内启用(调用方控制),避免把用户隔了很久的正常复述误杀。
enum LingShuEchoDetector {
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    /// `utterance` 是否是 `recentOutputs`(灵枢最近说/回复的若干句)中任一句的回声。
    static func isEcho(_ utterance: String, recentOutputs: [String]) -> Bool {
        let u = normalize(utterance)
        guard u.count >= 2 else { return false }   // 太短不可靠,交给别的门
        for out in recentOutputs {
            let o = normalize(out)
            guard o.count >= 2 else { continue }
            // 互为子串:回声常是说出口那句的片段("好的"⊂"好的,请说");或整句回声。
            if o.contains(u) || u.contains(o) { return true }
            // 长串高字符重合(ASR 把 TTS 听岔了几个字)。
            if u.count >= 4, overlapRatio(u, o) >= 0.75 { return true }
        }
        return false
    }

    private static func overlapRatio(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty else { return 0 }
        let bset = Set(b)
        return Double(a.filter { bset.contains($0) }.count) / Double(a.count)
    }
}
