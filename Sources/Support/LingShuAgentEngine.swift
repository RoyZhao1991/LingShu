import Foundation

/// 步骤1·派生子 agent 的「执行引擎」抽象(纯类型 + 选择逻辑,可单测)。
///
/// 背景:派生一个子 agent 现在写死成「gateway 模型驱动的循环」(`makeAgentSession(model: adapter)`)。
/// 但「模型」(per-turn 补全,灵枢循环在外)和「agent」(Codex/Claude Code,自带整任务循环)是两个物种——
/// 把 Codex 这种 agent 塞进 model 槽就是「错位」。这里把派生 agent 的执行抽成**引擎**,后续可插拔:
/// - `localBrain`:灵枢自己的 agent 循环 + 某个模型适配器(现状,行为不变)。
/// - `externalCLI`:一次性委托给外部 agent CLI(Codex / 未来 Claude Code,执行接线见步骤2/3)。
///
/// 本文件只含**纯类型 + 池/异源逻辑**(可单测、0 模型依赖);与 live 状态的接线见 `LingShuState+AgentEngine`。
/// 这是后续 resolver(选 maker/checker 组合)要消费的「可用引擎池」的来源与独立性判据。
enum LingShuAgentEngineKind: String, Sendable, Equatable, Codable {
    case localBrain      // 本地脑驱动的循环引擎(灵枢自己干)
    case externalCLI     // 外部 agent CLI 一次性委托引擎(Codex / Claude Code)
}

/// 一个可派生 agent 的引擎描述符(纯数据,可枚举/比较/测)。
struct LingShuAgentEngineDescriptor: Sendable, Equatable, Identifiable {
    let id: String            // 唯一标识(如 localBrain:deepseek / external:codex)
    let kind: LingShuAgentEngineKind
    let providerLabel: String // 人读来源(DeepSeek / MiniMax / Codex / Claude Code)
    let available: Bool       // 当前是否可用(localBrain 看是否配脑;externalCLI 看 CLI 登录/安装)

    /// 异源判据的「来源指纹」:同 kind 且同 provider = 同源。resolver 据此把 checker 选成跨源(真独立)。
    /// 归一化大小写 + 去空白,避免 "DeepSeek"/"deepseek" 被误判成两源。
    var sourceFingerprint: String {
        "\(kind.rawValue):\(providerLabel.lowercased().trimmingCharacters(in: .whitespaces))"
    }
}

/// 可用引擎池(纯逻辑):汇总 → 只留可用 → 按 id 去重(先到先得,保序)。
/// resolver 从这里取 (maker, checker) 候选;maker 由现有复杂度路由给定,checker 优先取与其异源的一个。
enum LingShuAgentEngineRegistry {
    /// 过滤出可用引擎,按 id 去重保序。
    static func availablePool(_ descriptors: [LingShuAgentEngineDescriptor]) -> [LingShuAgentEngineDescriptor] {
        var seen = Set<String>()
        var out: [LingShuAgentEngineDescriptor] = []
        for d in descriptors where d.available {
            guard !seen.contains(d.id) else { continue }
            seen.insert(d.id)
            out.append(d)
        }
        return out
    }

    /// 两个引擎是否异源(跨 provider / 跨 CLI)——maker≠checker 独立性的核心判据。
    static func areCrossSource(_ a: LingShuAgentEngineDescriptor, _ b: LingShuAgentEngineDescriptor) -> Bool {
        a.sourceFingerprint != b.sourceFingerprint
    }

    /// 在池中为给定 maker 选一个「最独立的 checker」:优先异源;无异源可用则落回同源(=当前行为)。
    /// 纯逻辑、确定性(非打分优化):异源候选取池中第一个(保序=配置/枚举顺序),无则返回 maker 自身(同源兜底)。
    /// 返回 (checker, crossSource):crossSource=false 表示退化成同源审查(独立性弱,调用方可据此落 trace 提示配第二源)。
    static func pickChecker(forMaker maker: LingShuAgentEngineDescriptor,
                            from pool: [LingShuAgentEngineDescriptor])
        -> (checker: LingShuAgentEngineDescriptor, crossSource: Bool) {
        if let crossSource = pool.first(where: { areCrossSource($0, maker) }) {
            return (crossSource, true)
        }
        return (maker, false)
    }
}
