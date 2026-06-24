import Foundation

/// 通用中枢 P2·**能力缺口分析(GapAnalyzer)**(纯类型 + 容错解析,可单测)。
///
/// 面对一个目标,**执行前**先判"以我当前能力(含可立即自我扩展补齐的)能不能做成";不能则指出缺口 + 补齐路径。
/// 这让"超出当前能力的目标不简单拒绝,而是说明缺口、规划补齐、在授权内尝试扩展"成真(见 `Docs/通用AI中枢推进方案.md` P2)。
/// 模型驱动(据能力快照判断,零领域分支),解析容错。结果注入执行引导 + 落记录,**不硬阻断执行**(诚实告知 + 引导补齐)。
enum LingShuGapKind: String, Codable, Sendable, Equatable {
    case model              // 需要更强/特定模型能力
    case tool               // 缺某个工具
    case device             // 缺硬件/外设
    case permission         // 缺系统/账号授权
    case knowledge          // 缺资料/领域知识
    case resource           // 缺素材/模板/数据
    case funding            // 需要钱/付费
    case humanConfirmation  // 需人确认/提供凭据
    case unknown
}

struct LingShuCapabilityGap: Codable, Sendable, Equatable {
    var kind: LingShuGapKind
    var missing: String     // 缺什么
    var fillPath: String    // 怎么补(优先自我扩展:author_component/discover_skill/acquire_resource/discover_devices/连 MCP;真补不了才指向用户)
    var blocking: Bool      // true=没它做不成;false=可降级/可绕过
    /// 是否已被解除(用户已提供凭据/授权,或灵枢已自补)。解除后完成闸不再据它阻断/再问——根治"给了 token 仍循环再问"。
    var resolved: Bool = false

    /// 必须用户参与才能补(凭据/授权/付费/物理设备)——这类不可灵枢自补,真缺就 waitingForUser。
    var requiresUser: Bool { [.humanConfirmation, .permission, .funding, .device].contains(kind) }

    /// 灵枢可自主补齐(写工具/找技能/取素材/补知识)——应先驱动去获取,而不是直接交还用户。
    var selfAcquirable: Bool { [.tool, .knowledge, .resource, .model].contains(kind) }

    enum CodingKeys: String, CodingKey { case kind, missing, fillPath, blocking, resolved }

    init(kind: LingShuGapKind, missing: String, fillPath: String, blocking: Bool, resolved: Bool = false) {
        self.kind = kind; self.missing = missing; self.fillPath = fillPath; self.blocking = blocking; self.resolved = resolved
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(LingShuGapKind.self, forKey: .kind)
        missing = try c.decode(String.self, forKey: .missing)
        fillPath = (try? c.decode(String.self, forKey: .fillPath)) ?? ""
        blocking = (try? c.decode(Bool.self, forKey: .blocking)) ?? false
        resolved = (try? c.decodeIfPresent(Bool.self, forKey: .resolved)) ?? false   // 旧记录无此键→false,向后兼容
    }
}

struct LingShuGapAnalysis: Codable, Sendable, Equatable {
    var feasibleNow: Bool   // 现有能力(含可立即自我扩展补齐的)是否足以完成
    var gaps: [LingShuCapabilityGap]
    var note: String        // 一句话结论 / 补齐策略

    var hasBlockingGap: Bool { gaps.contains { $0.blocking && !$0.resolved } }

    /// 阻断缺口集(P2 真闭环:完成闸据此判"未解除阻断")——**只算未解除的**(已解除的不再阻断/再问)。
    var blockingGaps: [LingShuCapabilityGap] { gaps.filter { $0.blocking && !$0.resolved } }
    /// 阻断缺口里**有需用户参与**的(凭据/授权/付费/物理)→ waitingForUser。
    var blockingNeedsUser: Bool { blockingGaps.contains { $0.requiresUser } }
    /// 阻断缺口里**有可灵枢自补**的 → 应先驱动获取。
    var blockingSelfAcquirable: Bool { blockingGaps.contains { $0.selfAcquirable } }

    /// 有需用户提供的阻断前提(凭据/授权/付费/硬件)——执行前应主动用 ask_user 跟用户确认。
    var needsUserToUnblock: Bool {
        blockingGaps.contains { [.humanConfirmation, .permission, .funding, .device].contains($0.kind) }
    }

    /// 人可读摘要(落 trace / 任务记录)。
    var summary: String {
        if feasibleNow && gaps.isEmpty { return "能力评估:现有能力足以完成。\(note.isEmpty ? "" : note)" }
        var lines = ["能力评估:\(feasibleNow ? "可经自我扩展补齐后完成" : "当前能力不足")。"]
        for g in gaps {
            lines.append("- 缺[\(g.kind.rawValue)]\(g.blocking ? "(阻断)" : "(可绕)"):\(g.missing) → 补齐:\(g.fillPath)")
        }
        if !note.isEmpty { lines.append("策略:\(note)") }
        return lines.joined(separator: "\n")
    }

    /// 注入执行引导:有缺口时让执行模型**先按补齐路径取得能力再推进**(没缺口则不加压、返回 base)。
    /// P2 补齐:有需用户提供的阻断前提(凭据/授权/付费/硬件)时,明确指示**先用 ask_user 跟用户确认拿到**(主动澄清)。
    func executionGuidance(base: String?) -> String {
        guard !gaps.isEmpty else { return base ?? "" }
        var block = "【能力缺口与补齐计划(执行前评估,据此先补齐再推进;真补不了的如实告知用户并给替代,别假装完成)】\n\(summary)"
        if needsUserToUnblock {
            block += "\n⚠️ 有**需用户提供的前提**(凭据/授权/付费/硬件)→ **先用 ask_user 跟用户确认拿到再推进**;真拿不到就如实交代 + 给替代方案,绝不假装完成。"
        }
        guard let b = base?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return block }
        return b + "\n\n" + block
    }
}

enum LingShuGapAnalyzer {
    /// 给模型的能力评估指令(嵌入能力快照)。强调:能自己补的别当"拒绝",标 gap 但 fill_path 写自我扩展手段。
    static func systemPrompt(capabilities: String) -> String {
        """
        你是能力评估器。判断"以你**当前能力**(含可立即自我扩展补齐的)能否完成用户这个目标",不能则指出缺口 + 补齐路径。**只输出 JSON**(不要解释、不要 markdown 围栏)。

        你当前可用能力:
        \(capabilities)

        你还能**自我扩展能力**(缺工具≠做不了):
        - author_component:据需求/API 文档自写一个工具(或传感器/执行器组件),沙箱测 + 安全门后上线
        - discover_skill:联网找现成技能装上
        - acquire_resource:联网获取模板/图标/字体/参考素材入库
        - discover_devices:枚举本机硬件/外设并接入
        - 连接新的 MCP server 获取其工具

        字段:
        - feasible_now: 现有能力(含可立即自我扩展补齐的)是否足以完成 → true/false
        - gaps: 数组,每项 {kind, missing, fill_path, blocking}。kind 八选一:model/tool/device/permission/knowledge/resource/funding/human_confirmation。
          missing=缺什么;fill_path=怎么补(**优先用上面的自我扩展手段**,真补不了才写需用户提供什么);blocking=没它就做不成(true)/可降级或绕过(false)。无缺口给 []。
        - note: 一句话结论(能做就说思路;不能立即做就说补齐策略)

        铁律:能自己补的(写工具/找技能/下素材/接设备)**别当缺口拒绝**——标成 gap 但 fill_path 写明自我扩展手段、blocking 按是否真卡住判;**只有真需要外部(钱 / 凭据 / 物理设备 / 人授权)才标 blocking=true 且 kind=funding/human_confirmation/device/permission**。
        """
    }

    /// 容错解析:剥围栏 + 取首个 {...} + JSON 解析。无有效结构 → nil(按"未评估"处理)。
    static func parse(_ raw: String) -> LingShuGapAnalysis? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // feasible_now 必须存在(布尔),否则视为解析失败。
        guard let feasible = obj["feasible_now"] as? Bool else { return nil }
        let gaps: [LingShuCapabilityGap] = ((obj["gaps"] as? [Any]) ?? []).compactMap { item in
            guard let g = item as? [String: Any] else { return nil }
            let missing = ((g["missing"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !missing.isEmpty else { return nil }
            let rawKind = ((g["kind"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: LingShuGapKind
            switch rawKind.lowercased().replacingOccurrences(of: "-", with: "_") {
            case "model": kind = .model
            case "tool": kind = .tool
            case "device": kind = .device
            case "permission": kind = .permission
            case "knowledge": kind = .knowledge
            case "resource": kind = .resource
            case "funding": kind = .funding
            case "human_confirmation", "humanconfirmation": kind = .humanConfirmation
            default: kind = LingShuGapKind(rawValue: rawKind) ?? .unknown
            }
            return LingShuCapabilityGap(
                kind: kind,
                missing: missing,
                fillPath: ((g["fill_path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                blocking: (g["blocking"] as? Bool) ?? false
            )
        }
        let note = ((obj["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return LingShuGapAnalysis(feasibleNow: feasible, gaps: gaps, note: note)
    }
}
