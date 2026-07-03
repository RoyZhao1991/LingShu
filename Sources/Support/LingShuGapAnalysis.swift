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

/// 授权弹窗协议字段。
///
/// 重要:弹授权窗只看这个结构化字段,不从回复文本里扫“授权/token/OAuth/登录”等词。
/// `OAuth == nil` 或 `required == false` 时,UI 不得弹授权窗口。
struct LingShuOAuthAuthorizationOption: Codable, Sendable, Equatable {
    var label: String
    var detail: String?

    init(label: String, detail: String? = nil) {
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ raw: Any) -> LingShuOAuthAuthorizationOption? {
        if let text = raw as? String {
            let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? nil : .init(label: label)
        }
        guard let obj = raw as? [String: Any] else { return nil }
        let label = ((obj["label"] as? String) ?? (obj["title"] as? String) ?? (obj["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let detail = ((obj["detail"] as? String) ?? (obj["description"] as? String) ?? (obj["reason"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(label: label, detail: detail)
    }
}

struct LingShuOAuthAuthorizationRequest: Codable, Sendable, Equatable {
    var required: Bool
    var target: String
    var action: String
    var reason: String
    var question: String
    var options: [LingShuOAuthAuthorizationOption]

    init(required: Bool,
         target: String = "",
         action: String = "",
         reason: String = "",
         question: String = "",
         options: [LingShuOAuthAuthorizationOption] = []) {
        self.required = required
        self.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        self.action = action.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        self.options = options
            .map { .init(label: $0.label, detail: $0.detail) }
            .filter { !$0.label.isEmpty }
    }

    var isActive: Bool {
        required && (!question.isEmpty || !target.isEmpty || !action.isEmpty || !reason.isEmpty)
    }

    var normalized: LingShuOAuthAuthorizationRequest? {
        guard isActive else { return nil }
        var copy = self
        if copy.question.isEmpty {
            let subject = [copy.target, copy.action].filter { !$0.isEmpty }.joined(separator: " / ")
            copy.question = subject.isEmpty
                ? "这一步需要授权后才能继续。"
                : "这一步需要你确认授权: \(subject)"
        }
        if copy.options.isEmpty {
            copy.options = [
                .init(label: "确认授权,继续", detail: "我已完成授权或提供了所需凭据,继续当前任务。"),
                .init(label: "暂不授权", detail: "先停在这里,不要继续访问该资源。"),
                .init(label: "改用替代方案", detail: "不走这项授权,尝试只读或可逆替代路径。")
            ]
        }
        return copy
    }

    static func parse(_ raw: Any?) -> LingShuOAuthAuthorizationRequest? {
        guard let raw else { return nil }
        if let required = raw as? Bool {
            return required ? .init(required: true, question: "这一步需要授权后才能继续。") : nil
        }
        guard let obj = raw as? [String: Any] else { return nil }
        let required = (obj["required"] as? Bool)
            ?? (obj["need_auth"] as? Bool)
            ?? (obj["needs_auth"] as? Bool)
            ?? false
        let options = ((obj["options"] as? [Any]) ?? []).compactMap(LingShuOAuthAuthorizationOption.parse)
        let request = LingShuOAuthAuthorizationRequest(
            required: required,
            target: ((obj["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            action: ((obj["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            reason: ((obj["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            question: ((obj["question"] as? String) ?? (obj["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            options: options
        )
        return request.normalized
    }
}

struct LingShuGapAnalysis: Codable, Sendable, Equatable {
    var feasibleNow: Bool   // 现有能力(含可立即自我扩展补齐的)是否足以完成
    var gaps: [LingShuCapabilityGap]
    var note: String        // 一句话结论 / 补齐策略
    /// 授权弹窗协议字段。为空时绝不弹授权窗。
    var OAuth: LingShuOAuthAuthorizationRequest?

    init(feasibleNow: Bool,
         gaps: [LingShuCapabilityGap],
         note: String,
         OAuth: LingShuOAuthAuthorizationRequest? = nil) {
        self.feasibleNow = feasibleNow
        self.gaps = gaps
        self.note = note
        self.OAuth = OAuth?.normalized
    }

    var hasBlockingGap: Bool { OAuth?.normalized != nil || gaps.contains { $0.blocking && !$0.resolved } }

    /// 阻断缺口集(P2 真闭环:完成闸据此判"未解除阻断")——**只算未解除的**(已解除的不再阻断/再问)。
    var blockingGaps: [LingShuCapabilityGap] { gaps.filter { $0.blocking && !$0.resolved } }
    /// 阻断缺口里**有需用户参与**的(凭据/授权/付费/物理)→ waitingForUser。
    var blockingNeedsUser: Bool { OAuth?.normalized != nil || blockingGaps.contains { $0.requiresUser } }
    /// 阻断缺口里**有可灵枢自补**的 → 应先驱动获取。
    var blockingSelfAcquirable: Bool { blockingGaps.contains { $0.selfAcquirable } }

    /// 有需用户提供的阻断前提(凭据/授权/付费/硬件)——执行前应主动用 ask_user 跟用户确认。
    var needsUserToUnblock: Bool {
        OAuth?.normalized != nil || blockingGaps.contains { [.humanConfirmation, .permission, .funding, .device].contains($0.kind) }
    }

    /// 人可读摘要(落 trace / 任务记录)。
    var summary: String {
        if feasibleNow && gaps.isEmpty { return "能力评估:现有能力足以完成。\(note.isEmpty ? "" : note)" }
        var lines = ["能力评估:\(feasibleNow ? "可经自我扩展补齐后完成" : "当前能力不足")。"]
        for g in gaps {
            lines.append("- 缺[\(g.kind.rawValue)]\(g.blocking ? "(阻断)" : "(可绕)"):\(g.missing) → 补齐:\(g.fillPath)")
        }
        if let oauth = OAuth?.normalized {
            lines.append("- OAuth(授权弹窗):\(oauth.question)")
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
        - OAuth: 授权弹窗协议字段。只有当前目标**真正需要用户授权/凭据/付费/物理确认后才能继续执行**时才输出对象:
          {"required":true,"target":"受保护对象","action":"要执行的动作","reason":"为什么需要授权","question":"给用户看的授权问题","options":[{"label":"确认授权,继续","detail":"..."},{"label":"暂不授权","detail":"..."},{"label":"改用替代方案","detail":"..."}]}
          否则必须输出 null。普通知识问答、解释 OAuth/token/登录原理、普通文本回复、已能直接完成的任务,都必须是 "OAuth": null。

        铁律:能自己补的(写工具/找技能/下素材/接设备)**别当缺口拒绝**——标成 gap 但 fill_path 写明自我扩展手段、blocking 按是否真卡住判;**只有真需要外部(钱 / 凭据 / 物理设备 / 人授权)才标 blocking=true 且 kind=funding/human_confirmation/device/permission**。
        铁律:授权窗口只由 OAuth 字段控制;不要因为文本里出现"授权/token/OAuth/登录/权限"就设置 OAuth,除非当前操作真的需要用户给授权才能继续。
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
        let oauth = LingShuOAuthAuthorizationRequest.parse(obj["OAuth"] ?? obj["oauth"])
        return LingShuGapAnalysis(feasibleNow: feasible, gaps: gaps, note: note, OAuth: oauth)
    }
}
