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

    /// 脑当前是否"已证明足够强"(脑力旋钮的判据):**优先用生产/真编码主导的测评分**(≥85),
    /// 否则看运行累计分(≥12 次净正)。测评分是产线能力的真实度量,故据它放权不会被有界谜题刷高误判。
    var brainProvenStrong: Bool {
        if let b = brainBenchmarkResult?.score { return b >= 85 }
        return brainScore.score >= 12
    }

    /// 脑力旋钮(方案"框架随脑力可调"):脑被证明强 → 在系统提示最前面**放权**(自行决定是否 update_plan、
    /// 验收从简、按最优路径高效推进,别被流程束缚);弱脑则保留厚脚手架(返回空串=不改原提示)。
    /// **安全红线不随旋钮放松**(不可逆/对外先确认、危险代码不静默执行)。这让"强脑→薄 harness"真正生效。
    func harnessKnobPrefix() -> String {
        guard brainProvenStrong else { return "" }
        let tag = brainBenchmarkResult.map { "脑力测评 \($0.score) 分" } ?? "运行表现稳定"
        return "【能力旋钮·已放权】你已被评为高能力脑(\(tag)):多步任务**可自行判断**是否先调 update_plan(不强制)、验收从简,放手按你最优路径高效推进,别被流程细则束缚。**唯一不放松的是安全红线**:不可逆/对外动作仍先确认,危险/未审代码绝不静默执行。\n\n"
    }

    nonisolated static func loadBrainScore() -> LingShuBrainScore {
        guard let data = UserDefaults.standard.data(forKey: brainScoreKey),
              let s = try? JSONDecoder().decode(LingShuBrainScore.self, from: data) else {
            return LingShuBrainScore(brainID: "")
        }
        return s
    }
}
