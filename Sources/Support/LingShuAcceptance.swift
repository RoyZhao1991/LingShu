import Foundation

/// 通用中枢 P3·**按 GoalSpec 成功标准做全类型验收**(纯类型 + 容错解析 + 确定性裁决,可单测)。
///
/// P1 把成功标准结构化进 GoalSpec,但原本只作为「一段文本」喂给 LLM 评审官凭知识判("逐条核对是否真达成");
/// P3 把每条成功标准**分类型**,凡能被宿主侧事实确定性核验的(文件存在 / 命令·测试成功),用**文件系统 + 执行记录证据**
/// 直接裁决,不靠模型自说自话;不能确定性核验的(设备效果 / 环境改变 / 用户确认)如实标 `unverifiable`(**绝不幻觉为已达成**);
/// 主观的(内容质量/正确性)交 LLM 评审官判。**任一确定性条不达成 → 硬门返工**,模型口头"已完成"不能推翻文件系统事实。
/// 见 `Docs/通用AI中枢推进方案.md` P3。模型只负责把成功标准**分类 + 给探针**(零领域分支),解析容错;裁决逻辑纯函数。
enum LingShuCriterionKind: String, Codable, Sendable, Equatable {
    case fileExists        // 产出文件/目录存在 → 可据 FileManager 确定性核验
    case commandSucceeds   // 构建/测试/命令成功 → 可据执行记录确定性裁决
    case deviceEffect      // 设备/外设物理状态改变 → 宿主侧暂不能自动核验
    case environmentChange // 系统/环境状态改变 → 宿主侧暂不能自动核验
    case userConfirmation  // 需用户确认/满意 → 只能由用户判
    case contentQuality    // 内容正确性/质量/完整性 → 主观,交 LLM 评审官
    case unknown

    /// 能否用宿主侧事实(文件系统 / 执行记录)确定性核验——只有这两类不靠模型自说自话。
    var isDeterministic: Bool { self == .fileExists || self == .commandSucceeds }
}

/// 一条分类后的验收检查项(模型据成功标准产出:类型 + 确定性探针)。
struct LingShuAcceptanceCheck: Codable, Sendable, Equatable {
    var kind: LingShuCriterionKind
    var criterion: String   // 原成功标准文本(原样)
    var probe: String?      // 确定性探针:fileExists→文件路径或文件名(可相对工作目录,支持 *.ext 线索);commandSucceeds→期望成功的命令子串
}

enum LingShuCheckStatus: String, Codable, Sendable, Equatable {
    case met           // 确定性核实已达成
    case unmet         // 确定性核实**未达成** → 硬门返工
    case unverifiable  // 宿主侧无法确定性核验(设备/环境/用户确认/内容质量/缺探针)→ 交 LLM/用户,不计硬门
}

/// 一条成功标准的裁决结果(状态 + 证据)。
struct LingShuCheckVerdict: Codable, Sendable, Equatable {
    var criterion: String
    var kind: LingShuCriterionKind
    var status: LingShuCheckStatus
    var evidence: String
}

/// 全类型验收报告(逐条裁决 + 合并结论)。typed,随任务记录持久化跨重启,供用户验收时逐条核对。
struct LingShuAcceptanceReport: Codable, Sendable, Equatable {
    var verdicts: [LingShuCheckVerdict]
    var note: String

    var isEmpty: Bool { verdicts.isEmpty }

    /// 有确定性核实**未达成**的条 → 硬门返工(文件不存在 / 测试没绿等),模型不得推翻。
    var hasDeterministicFailure: Bool { verdicts.contains { $0.status == .unmet } }
    var deterministicFailures: [LingShuCheckVerdict] { verdicts.filter { $0.status == .unmet } }
    var deterministicallyMet: [LingShuCheckVerdict] { verdicts.filter { $0.status == .met } }
    var unverifiable: [LingShuCheckVerdict] { verdicts.filter { $0.status == .unverifiable } }

    /// 人可读摘要(落 trace / 任务记录 / 验收说明)。
    var summary: String {
        guard !verdicts.isEmpty else { return "通用验收:本任务无结构化成功标准。" }
        var lines = ["通用验收(成功标准逐条核验):"]
        for v in verdicts {
            let mark = v.status == .met ? "✅" : (v.status == .unmet ? "❌" : "◽")
            lines.append("\(mark)[\(v.kind.rawValue)] \(v.criterion) — \(v.evidence)")
        }
        if !note.isEmpty { lines.append("结论:\(note)") }
        return lines.joined(separator: "\n")
    }

    /// 注入 LLM 评审官的「成功标准确定性核验结果」块:met/unmet 是宿主裁定的**权威事实不可推翻**;
    /// ◽ 待判的里——content_quality 由评审官据正文判,device/environment/user_confirmation 宿主无法自动确认、须在结论里如实提示需用户确认。
    var verifierBlock: String {
        guard !verdicts.isEmpty else { return "" }
        var lines = ["【成功标准确定性核验(宿主已据文件系统/执行记录裁决——✅达成/❌未达成是权威事实,不可因「无法独立验证」推翻;◽ 待你或用户判)】"]
        for v in verdicts {
            let mark = v.status == .met ? "✅达成" : (v.status == .unmet ? "❌未达成" : "◽待判")
            lines.append("- [\(v.kind.rawValue)] \(v.criterion):\(mark)(\(v.evidence))")
        }
        lines.append("◽content_quality 请你据正文逐条判定;◽device/environment/user_confirmation 宿主无法自动确认 → 结论里如实提示「需用户确认」,**不要假定已达成**。")
        return lines.joined(separator: "\n")
    }

    /// 硬门返工指引(确定性条未达成时回灌给 maker)。
    var deterministicFailureReason: String {
        let detail = deterministicFailures
            .map { "[\($0.kind.rawValue)] \($0.criterion) — \($0.evidence)" }
            .joined(separator: "\n")
        return "[通用验收] ❌ 成功标准里**能确定性核验的条目未达成**,直接返工:\n\(detail)\n请补到这些条目真达成(产出对应文件 / 真跑成功对应命令)再交付,别声称完成。"
    }

    /// 纯裁决:给定分类后的检查项 + 宿主侧事实闭包,逐条产出 verdict。
    /// - fileExists(probe) → 文件是否存在
    /// - commandSucceeded(probe) → 命令出现且成功=true / 出现但失败=false / 从未出现=nil(无法核验)
    static func make(
        checks: [LingShuAcceptanceCheck],
        fileExists: (String) -> Bool,
        commandSucceeded: (String) -> Bool?,
        note: String = ""
    ) -> LingShuAcceptanceReport {
        let verdicts = checks.map { check -> LingShuCheckVerdict in
            let probe = (check.probe ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            func verdict(_ status: LingShuCheckStatus, _ evidence: String) -> LingShuCheckVerdict {
                LingShuCheckVerdict(criterion: check.criterion, kind: check.kind, status: status, evidence: evidence)
            }
            switch check.kind {
            case .fileExists:
                guard !probe.isEmpty else { return verdict(.unverifiable, "无探针路径,无法确定性核验文件存在") }
                return fileExists(probe)
                    ? verdict(.met, "文件系统已核实存在:\(probe)")
                    : verdict(.unmet, "文件系统未找到:\(probe)")
            case .commandSucceeds:
                guard !probe.isEmpty else { return verdict(.unverifiable, "无探针命令,无法确定性核验") }
                switch commandSucceeded(probe) {
                case .some(true):  return verdict(.met, "执行记录里有成功执行的命令:\(probe)")
                case .some(false): return verdict(.unmet, "执行记录里该命令未成功(失败/崩溃):\(probe)")
                case .none:        return verdict(.unverifiable, "执行记录里没有匹配该探针的命令:\(probe)")
                }
            case .deviceEffect:
                return verdict(.unverifiable, "设备/外设物理效果宿主侧暂不能自动核验(需设备回读或用户确认)")
            case .environmentChange:
                return verdict(.unverifiable, "环境/系统状态改变宿主侧暂不能自动核验")
            case .userConfirmation:
                return verdict(.unverifiable, "需用户确认,只能由用户判定")
            case .contentQuality:
                return verdict(.unverifiable, "内容正确性/质量交评审官判定")
            case .unknown:
                return verdict(.unverifiable, "未能分类的成功标准,交评审官判定")
            }
        }
        return LingShuAcceptanceReport(verdicts: verdicts, note: note)
    }
}

enum LingShuAcceptancePlanner {
    /// 给模型的验收项分类指令(成功标准从 user 消息传入,system 静态可缓存)。
    static let systemPrompt = """
    你是验收项分类器。把用户给的「成功标准」逐条分成可核验的类型,并尽量给出确定性探针。**只输出 JSON 数组**(不要解释、不要 markdown 围栏)。

    每项输出 {criterion, kind, probe}:
    - criterion:原成功标准文本(**原样照抄**,不要改写)
    - kind 六选一:
      - file_exists:要求某产出文件/目录存在。probe 写该文件路径或文件名(如 "report.pdf");不确定具体名就给扩展名线索 "*.pptx"
      - command_succeeds:要求构建/测试/命令成功。probe 写期望成功的命令子串(如 "swift test"、"pytest"、"npm test")
      - device_effect:要求某设备/外设物理状态改变(开灯/调温/机器人动作等)。probe 留空
      - environment_change:要求系统/环境状态改变(进程启动、配置生效、服务可访问等)。probe 留空
      - user_confirmation:要求用户确认/满意/验收。probe 留空
      - content_quality:要求内容正确/完整/质量/风格等主观维度。probe 留空
    - probe:确定性探针(仅 file_exists / command_succeeds 需要),其余留空字符串 ""

    铁律:**能落到「文件存在」或「命令·测试成功」的尽量分到 file_exists / command_succeeds 并给出 probe**——这两类是唯一能被宿主确定性核验、不靠模型自说自话的;其余按真实语义分类,不要硬塞。
    """

    /// 容错解析:剥围栏 + 取首个 [...] 数组 + 逐项解析。
    /// 铁律:模型少返/漏返/乱返时,仍按原成功标准逐条返回检查项,缺失项回退为 content_quality,绝不静默丢条。
    static func parse(_ raw: String, fallbackCriteria: [String]) -> [LingShuAcceptanceCheck] {
        let cleaned = fallbackCriteria
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallback = cleaned.map(Self.heuristicCheck)

        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return fallback }

        let parsed: [LingShuAcceptanceCheck] = arr.compactMap { item in
            guard let obj = item as? [String: Any] else { return nil }
            let criterion = ((obj["criterion"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !criterion.isEmpty else { return nil }
            let probeRaw = ((obj["probe"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return LingShuAcceptanceCheck(kind: parseKind(obj["kind"] as? String), criterion: criterion,
                                          probe: probeRaw.isEmpty ? nil : probeRaw)
        }
        guard !parsed.isEmpty else { return fallback }
        guard !cleaned.isEmpty else { return parsed }

        // 常见正常路径:模型按原顺序返回同样数量的检查项。即使 criterion 被轻微改写,
        // 也用原成功标准文本覆盖回去,保证验收报告与 GoalSpec 一一对应。
        if parsed.count == cleaned.count {
            return zip(cleaned, parsed).map { original, check in
                preferDeterministicHeuristic(original: original,
                                             parsed: LingShuAcceptanceCheck(kind: check.kind, criterion: original, probe: check.probe))
            }
        }

        // 异常路径:模型漏项/多项。只采用能按原文匹配上的分类;没匹配上的原标准退回 content_quality。
        var used = Set<Int>()
        return cleaned.map { original in
            let key = normalizeCriterion(original)
            if let idx = parsed.indices.first(where: { !used.contains($0) && normalizeCriterion(parsed[$0].criterion) == key }) {
                used.insert(idx)
                let check = parsed[idx]
                return preferDeterministicHeuristic(original: original,
                                                   parsed: LingShuAcceptanceCheck(kind: check.kind, criterion: original, probe: check.probe))
            }
            return heuristicCheck(original)
        }
    }

    /// 本地确定性启发式:模型分类失败/漏分时,常见文件与测试命令仍能被硬门覆盖。
    /// 零领域定制:只识别扩展名、路径、常见测试/构建命令这类通用信号。
    static func heuristicCheck(_ criterion: String) -> LingShuAcceptanceCheck {
        let c = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        if let probe = firstFileProbe(in: c) {
            return .init(kind: .fileExists, criterion: c, probe: probe)
        }
        if let probe = firstCommandProbe(in: c) {
            return .init(kind: .commandSucceeds, criterion: c, probe: probe)
        }
        return .init(kind: .contentQuality, criterion: c, probe: nil)
    }

    private static func preferDeterministicHeuristic(original: String, parsed: LingShuAcceptanceCheck) -> LingShuAcceptanceCheck {
        let heuristic = heuristicCheck(original)
        guard heuristic.kind.isDeterministic else { return parsed }
        if !parsed.kind.isDeterministic || (parsed.probe ?? "").isEmpty {
            return heuristic
        }
        return parsed
    }

    static func firstFileProbe(in text: String) -> String? {
        let pattern = #"(/[^\s，。；;:：'"]+\.(?:pptx|docx|pdf|html?|md|csv|json|txt|py|js|ts|tsx|jsx|swift|xlsx|png|jpe?g|wav|mp3|mp4)|[A-Za-z0-9_\-./\p{Han}]+?\.(?:pptx|docx|pdf|html?|md|csv|json|txt|py|js|ts|tsx|jsx|swift|xlsx|png|jpe?g|wav|mp3|mp4)|\*\.(?:pptx|docx|pdf|html?|md|csv|json|txt|py|js|ts|tsx|jsx|swift|xlsx|png|jpe?g|wav|mp3|mp4))"#
        return firstRegexMatch(pattern: pattern, in: text)
    }

    private static func firstCommandProbe(in text: String) -> String? {
        let lower = text.lowercased()
        let commands = [
            "swift test", "swift build", "pytest", "python -m pytest", "npm test", "npm run test",
            "npm run build", "yarn test", "pnpm test", "go test", "cargo test", "mvn test", "gradle test",
            "xcodebuild test"
        ]
        if let hit = commands.first(where: { lower.contains($0) }) { return hit }
        if lower.contains("测试") || lower.contains("全绿") || lower.contains("test") {
            return "test"
        }
        if lower.contains("构建") || lower.contains("编译") || lower.contains("build") {
            return "build"
        }
        return nil
    }

    private static func firstRegexMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    static func parseKind(_ raw: String?) -> LingShuCriterionKind {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "file_exists", "fileexists": return .fileExists
        case "command_succeeds", "commandsucceeds", "command", "test", "build": return .commandSucceeds
        case "device_effect", "deviceeffect", "device": return .deviceEffect
        case "environment_change", "environmentchange", "environment", "env": return .environmentChange
        case "user_confirmation", "userconfirmation", "user": return .userConfirmation
        case "content_quality", "contentquality", "content", "quality": return .contentQuality
        default: return .contentQuality   // 兜底交评审官,不丢
        }
    }

    private static func normalizeCriterion(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isNewline }
            .map(String.init)
            .joined()
    }
}
