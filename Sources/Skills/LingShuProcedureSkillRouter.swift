import Foundation

/// Record & Replay 的**确定性路由**(纯逻辑、可单测):识别「录制技能」「用某技能 replay」,从技能目录加载过程技能,
/// 抽取 replay 时口头给的参数。**确定性识别 + 大脑兜底**:触发命中走这里直达,不靠大脑瞎选(根治误调用)。
enum LingShuProcedureSkillRouter {

    /// 「记录一个技能」类请求 → 进录制模式。返回技能名(没说名字则 nil)。非录制请求返回 .none。
    static func detectRecordRequest(_ input: String) -> RecordRequest? {
        let t = input.trimmingCharacters(in: .whitespaces)
        let starters = ["记录一个技能", "记录技能", "录一个技能", "录制技能", "学一个技能", "看我做一遍", "看我操作一遍", "教你一个技能", "录个技能"]
        guard let hit = starters.first(where: { t.contains($0) }) else { return nil }
        // 抽技能名:命中词后面跟的「叫X / :X / 「X」」当名字。
        var name: String?
        if let r = t.range(of: hit) {
            var tail = String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,、叫名字为是"))
            for q in ["「", "『", "\""] { tail = tail.replacingOccurrences(of: q, with: "") }
            for q in ["」", "』", "\""] { tail = tail.replacingOccurrences(of: q, with: "") }
            let clean = tail.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty, clean.count <= 20 { name = clean }
        }
        return RecordRequest(name: name)
    }

    struct RecordRequest: Equatable { var name: String? }

    /// 在已加载技能里找 replay 目标:触发词命中即匹配;并抽出口头给的参数。无命中返回 nil。
    static func matchReplay(_ input: String, skills: [LingShuProcedureSkill]) -> ReplayMatch? {
        let t = input.replacingOccurrences(of: " ", with: "")
        let intents = ["用", "跑", "执行", "运行", "replay", "重放", "再做", "重做", "帮我做", "走一遍", "再来一遍"]
        // 命中最长触发词的那个技能(避免「报销」误中而「报销加班」该中更具体的)。
        // **2026-06-27 修误劫持**:① **忽略单字触发词**(如「打」——录制残留,子串匹配下任何含「打开/打字」的长请求都会误中);
        // ② 必须**显式调用**:输入以触发词开头,或执行动词**紧贴**触发词(「用输入文本」「跑报销」),而不是长任务里碰巧含触发词子串
        // (原来「帮我做一个PPT…打开…」因含「打」+泛意图「帮我做」就被劫持,根治)。
        var best: (skill: LingShuProcedureSkill, triggerLen: Int)?
        for skill in skills {
            for trig in skill.triggers {
                let key = trig.replacingOccurrences(of: " ", with: "")
                guard key.count >= 2 else { continue }   // 单字触发词太宽,跳过
                let explicit = t.hasPrefix(key) || intents.contains { t.contains($0 + key) }
                guard explicit, t.contains(key), best == nil || key.count > best!.triggerLen else { continue }
                best = (skill, key.count)
            }
        }
        guard let target = best?.skill else { return nil }
        return ReplayMatch(skill: target, params: extractParams(input, for: target))
    }

    struct ReplayMatch: Equatable { var skill: LingShuProcedureSkill; var params: [String: String] }

    /// 从口头里抽参数:「金额4800」「金额是4800」「日期6月20号」→ {金额:4800, 日期:6月20号}。
    /// 启发式兜底——抽不全的由 replay 流程让大脑补或问用户(missingParameters)。
    static func extractParams(_ input: String, for skill: LingShuProcedureSkill) -> [String: String] {
        var out: [String: String] = [:]
        let ns = input as NSString
        for p in skill.parameters {
            // name 后面跟 可选(是/为/:/：/=)+ 取到下一个分隔符前的值。
            let pat = "\(NSRegularExpression.escapedPattern(for: p.name))\\s*[:：=是为]?\\s*([^,，。、；;\\s]+)"
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            if let m = re.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                let v = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { out[p.name] = v }
            }
        }
        return out
    }

    /// 从技能目录加载所有**过程型**技能(.md 里 kind: procedure)。
    static func loadProcedures(from directory: URL = LingShuSkillLoader.defaultDirectory) -> [LingShuProcedureSkill] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> LingShuProcedureSkill? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return LingShuProcedureSkill.parse(markdown: text, fallbackID: url.deletingPathExtension().lastPathComponent)
            }
    }
}
