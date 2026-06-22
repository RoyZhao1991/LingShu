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

    /// 脑力旋钮(方案 §差距2"框架随脑力可调",2026-06-21 改连续起步档):脑力分 → **连续起步先验**(纯逻辑
    /// `LingShuHarnessProfile`),按能力分级给薄/中/厚三档起步提示,**无 85 二元硬跳变**(根治"一道偏题把强脑打回厚")。
    /// 真正的薄/厚由升级阶梯 `LingShuCapabilityEscalation` **按本次确定性结果反应式**加厚(默认最薄 Rung0)。
    /// **安全红线不随档位放松**(各档文案都含)。
    func harnessKnobPrefix() -> String {
        let capability = LingShuHarnessProfile.capability(benchmark: brainBenchmarkResult?.score, runNetScore: brainScore.score)
        let tag = brainBenchmarkResult.map { "脑力测评 \($0.score) 分" } ?? "运行表现 \(brainScore.score)"
        return LingShuHarnessProfile.knobPrefix(capability: capability, tag: tag)
    }

    nonisolated static func loadBrainScore() -> LingShuBrainScore {
        guard let data = UserDefaults.standard.data(forKey: brainScoreKey),
              let s = try? JSONDecoder().decode(LingShuBrainScore.self, from: data) else {
            return LingShuBrainScore(brainID: "")
        }
        return s
    }
}
