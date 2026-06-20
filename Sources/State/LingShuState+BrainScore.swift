import Foundation

/// 「大脑」评分接线(替代 TRUST):自主完成任务 +1 / 触发兜底 −1 / 换脑归零。
/// 纯计分逻辑在 `LingShuBrainScore`(可单测);这里只做 @Published 更新 + 持久化 + 在兜底/完成/换脑处打点。
@MainActor
extension LingShuState {

    nonisolated static let brainScoreKey = "lingshu.brainScore"

    /// 当前脑标识(provider|model);换它即换脑、评分归零。
    var currentBrainID: String { LingShuBrainScore.id(provider: modelProvider, model: modelName) }

    /// 自主推进完成一个任务 → +1(在 `finishTaskRecord(status: .completed)` 处打点)。
    func recordBrainTaskCompleted() {
        setBrainScore(brainScore.rebased(to: currentBrainID).taskCompleted())
    }

    /// 触发一次灵枢兜底逻辑 → −1(撞顶补预算 / 升级确定性兜底 / 验收停滞交还)。
    func recordBrainFallback(_ reason: String) {
        setBrainScore(brainScore.rebased(to: currentBrainID).fallbackTriggered())
        appendTrace(kind: .warning, actor: "脑力分", title: "兜底 −1", detail: "\(reason)(当前 \(brainScore.score) 分)")
    }

    /// 切换大模型 → 评分归零(评分只属于某一颗脑)。
    func resetBrainScoreForCurrentBrain() {
        setBrainScore(LingShuBrainScore(brainID: currentBrainID))
    }

    /// 启动时把加载到的分数对齐到当前脑(脑变了→归零),让顶栏一上来就显示当前脑的分。
    func rebaseBrainScoreToCurrentBrain() {
        let r = brainScore.rebased(to: currentBrainID)
        if r != brainScore { setBrainScore(r) }
    }

    private func setBrainScore(_ s: LingShuBrainScore) {
        brainScore = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.brainScoreKey) }
    }

    nonisolated static func loadBrainScore() -> LingShuBrainScore {
        guard let data = UserDefaults.standard.data(forKey: brainScoreKey),
              let s = try? JSONDecoder().decode(LingShuBrainScore.self, from: data) else {
            return LingShuBrainScore(brainID: "")
        }
        return s
    }
}
