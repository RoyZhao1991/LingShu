import Foundation

/// 脑力分 → **连续起步档先验**(差距2·薄基线,2026-06-21)。
///
/// 取代旧的**二元 harnessKnobPrefix**(脑力≥85 放权、否则不放):二元静态切**太脆**(98 分因一道字符级偏题
/// 跌破 85 就被打回厚)、**太粗**(能力是连续谱)。这里改:脑力分只定**起步提示档**(连续分级、无硬跳变),
/// 真正的薄/厚由升级阶梯 `LingShuCapabilityEscalation` **按本次确定性结果反应式**决定(默认最薄 Rung0,失败才加厚)。
///
/// 纯逻辑、可单测、通用零定制。**安全红线不随档位放松**(各档文案都保留"不可逆/对外先确认、危险代码不静默执行")。
enum LingShuHarnessProfile {

    /// 起步档(薄→厚三级,连续分级):lean=强脑起步最薄/提示最精简;balanced=中档;guided=弱脑起步带规划引导。
    enum Tier: String, Equatable { case lean, balanced, guided }

    /// 连续能力估计(0…100)。**基准分(产线能力真实度量)为主导**,运行净分做**有界微调**(避免有界谜题刷高/单次兜底打低)。
    /// 无基准时退化到以运行净分为中心的估计。
    static func capability(benchmark: Int?, runNetScore: Int) -> Double {
        if let b = benchmark {
            let boundedRun = Double(max(-10, min(10, runNetScore)))      // 运行净分有界 ±10
            return clamp(Double(b) + boundedRun * 0.3)                   // 微调幅度 ±3,基准主导
        }
        let boundedRun = Double(max(-30, min(30, runNetScore)))
        return clamp(50 + boundedRun)                                    // 无基准:50 基线 ± 运行表现
    }

    /// 能力分 → 起步档。阈值**带间隔**(75 / 50),不是单点 85 一刀切 → 小幅分数波动不翻档
    /// (98→90 仍 lean、98→74 落 balanced 而非直接 guided),根治"一道偏题把强脑打回厚"。
    static func tier(_ capability: Double) -> Tier {
        if capability >= 75 { return .lean }
        if capability >= 50 { return .balanced }
        return .guided
    }

    /// 起步档 → 系统提示前缀(随档连续变薄/变厚)。`tag`=能力来源标注(如"脑力测评 93 分")。
    /// **安全红线行恒在**,不随档位放松。
    static func knobPrefix(capability: Double, tag: String) -> String {
        let safety = "**唯一不放松的是安全红线**:不可逆/对外动作先确认,危险/未审代码绝不静默执行。"
        switch tier(capability) {
        case .lean:
            return "【能力旋钮·放权(\(tag))】你是高能力脑:多步任务**自行判断**是否先 update_plan(不强制),验收从简,放手按你最优路径高效推进,别被流程细则束缚。\(safety)\n\n"
        case .balanced:
            return "【能力旋钮·适度(\(tag))】复杂任务建议先快速理清步骤再动手;简单任务直接做。按需用 update_plan,不必逐项流程化。\(safety)\n\n"
        case .guided:
            return "【能力旋钮·引导(\(tag))】动手前先用 update_plan 列出步骤、逐步推进并自查;遇阻先想清楚再继续,别盲目重试。\(safety)\n\n"
        }
    }

    private static func clamp(_ x: Double) -> Double { max(0, min(100, x)) }
}
