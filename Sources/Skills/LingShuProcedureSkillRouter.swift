import Foundation

/// Record & Replay 的**确定性辅助**(纯逻辑、可单测):从技能目录加载过程技能、抽取 replay 时口头给的参数。
/// **2026-06-30 砍推断**:原「识别录制请求 / 匹配 replay 技能」的关键词嗅探(detectRecordRequest / matchReplay)已删——
/// 录制/重放改走**显式** `@录制` / `@<技能名>`(声明式层确定性覆盖),不再从裸句子里猜意图(根治「打→打开」误劫持)。
enum LingShuProcedureSkillRouter {

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
