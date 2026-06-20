import Foundation

/// 「大脑」评分(替代 TRUST):衡量**当前这颗脑**有多自主——纯逻辑可单测。
///
/// 与能力分层方案同源(框架介入频率与脑力成反比):
/// - **自主推进完成一个任务 → +1**(脑自己把活干完了)。
/// - **每触发一次灵枢兜底逻辑 → −1**(框架不得不替它兜:撞顶补预算 / 升级到确定性兜底 / 验收停滞交还)。
/// - **切换大模型 → 归零**(评分只属于某一颗脑;`brainID`=provider|model,换脑即 `rebased` 重置)。
///
/// 分数可正可负:强脑常年正分、弱脑(需大量兜底)会被压到负——这正是要看清的信号。
struct LingShuBrainScore: Codable, Equatable, Sendable {
    var brainID: String          // "provider|model",标识这分属于哪颗脑
    var score: Int = 0
    var completed: Int = 0       // 自主完成任务数(累计 +1 次数)
    var fallbacks: Int = 0       // 触发兜底次数(累计 −1 次数)

    static func id(provider: String, model: String) -> String { "\(provider)|\(model)" }

    /// 换脑归零:当前脑与记录的脑不一致 → 返回一个属于新脑的全新 0 分;一致则原样。
    func rebased(to brainID: String) -> LingShuBrainScore {
        self.brainID == brainID ? self : LingShuBrainScore(brainID: brainID)
    }

    /// 自主完成一个任务:+1。
    func taskCompleted() -> LingShuBrainScore {
        var s = self; s.completed += 1; s.score += 1; return s
    }

    /// 触发一次兜底:−1。
    func fallbackTriggered() -> LingShuBrainScore {
        var s = self; s.fallbacks += 1; s.score -= 1; return s
    }

    /// 给 HUD tooltip / 状态用的可读拆解。
    var summary: String {
        "脑力分 \(score) · 自主完成 +\(completed) / 触发兜底 −\(fallbacks) · 当前脑 \(brainID)"
    }
}
