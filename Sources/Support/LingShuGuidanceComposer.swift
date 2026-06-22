import Foundation

/// 通用中枢 P6+·**编译核心变体**示范(协议变体 + 特性开关,纯类型可单测)。
///
/// 「无界自进化」的安全模型是「任何改动都模块化、可一键切换、可一键回退」。对**运行时可插拔层**(提示/技能/脚本)
/// 这天然成立;对**编译进二进制的核心算法**,办法是:把核心逻辑抽成**协议**,给**多个编译期实现**(变体),
/// 用**特性开关(变体注册表的 payload=实现键)**在运行时**选**哪个已编译实现生效。
/// → 在**已存在的编译变体之间切换/回退是运行时的**(只是翻个 active 键,不重构);
///   **新增**一个编译核心变体才需过一次构建——但它一上线即纳入同一套「一键切换/回退」治理。
///
/// 这里以「执行引导的**组合核心**」为示范:历史经验块(P1→P2→P4 既有嵌套结果)与执行策略片段(可热切换槽位)
/// 如何拼成最终引导,本就是一个核心算法。不同大脑对"指令放前还是放后"的响应不同(呼应"按当前大脑动态调整"),
/// 所以给两个编译变体:策略**后置**(默认,行为同历史)/ 策略**前置**(对重视开头指令的大脑)。
protocol LingShuGuidanceComposing: Sendable {
    /// 实现键(= 变体注册表里该槽位的 payload;运行时据此选这个已编译实现)。
    static var key: String { get }
    /// 把「历史经验/目标/缺口引导」与「执行策略片段」组合成最终执行引导。任一为空都要优雅处理。
    func compose(experience: String, strategy: String) -> String
}

extension LingShuGuidanceComposing {
    /// 两段非空才用分隔拼接;一空则返回另一段(去重空白)。供各变体复用。
    func join(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + "\n\n" + y
    }
}

/// 默认/基线变体:经验在前、执行策略**后置**(与历史行为一致——切到它=回到原样)。
struct LingShuAppendStrategyComposer: LingShuGuidanceComposing {
    static let key = "append"
    func compose(experience: String, strategy: String) -> String { join(experience, strategy) }
}

/// 变体:执行策略**前置**(对"更看重开头指令"的大脑,把当前策略提到最前,经验随后)。
struct LingShuPrependStrategyComposer: LingShuGuidanceComposing {
    static let key = "prepend"
    func compose(experience: String, strategy: String) -> String { join(strategy, experience) }
}

/// 编译核心变体解析器:据特性开关(payload 键)选**已编译**实现;未知/空 → 默认 append(基线)。
enum LingShuGuidanceComposers {
    /// 全部已编译变体(新增一个核心变体=在这里多登记一个+过一次构建,随后即可热切换)。
    static let all: [LingShuGuidanceComposing] = [
        LingShuAppendStrategyComposer(),
        LingShuPrependStrategyComposer()
    ]

    static func resolve(_ key: String?) -> LingShuGuidanceComposing {
        let k = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { type(of: $0).key == k } ?? LingShuAppendStrategyComposer()
    }

    /// 可选键清单(供 UI/注册基线时列举)。
    static var availableKeys: [String] { all.map { type(of: $0).key } }
}
