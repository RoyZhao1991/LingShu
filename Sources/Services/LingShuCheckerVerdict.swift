import Foundation

/// Standard checker verdict envelope.
///
/// The checker may explain its reasoning inside fields, but the control plane only
/// reads typed JSON. Legacy "pass/fail" prose is intentionally not accepted as a
/// verdict, so review results cannot be routed by keyword matching.
struct LingShuCheckerVerdict: Equatable, Sendable {
    enum Outcome: String, Equatable, Sendable {
        case passed
        case failed
        case needsHumanInteraction = "needs_human_interaction"
    }

    struct Check: Equatable, Sendable {
        var name: String
        var passed: Bool
        var reason: String
    }

    var passed: Bool
    var confidence: Double?
    var summary: String
    var checks: [Check]
    var blockingIssues: [String]
    var evidence: [String]
    var needsUser: String?
    var humanInteraction: LingShuHumanInteractionRequest?

    /// `passed` is retained for backward compatibility with existing checker
    /// payloads. The control plane uses this tri-state outcome so waiting for a
    /// person is never interpreted as an ordinary rejection.
    var outcome: Outcome {
        if humanInteraction?.normalized != nil { return .needsHumanInteraction }
        return passed ? .passed : .failed
    }

    var renderedSummary: String {
        var lines: [String] = []
        switch outcome {
        case .passed: lines.append("✅ 验收通过")
        case .failed: lines.append("⚠️ 验收未通过")
        case .needsHumanInteraction: lines.append("⏸ 等待人机协作")
        }
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(summary)
        }
        if !checks.isEmpty {
            lines.append("检查项:")
            for check in checks {
                lines.append("- \(check.passed ? "✅" : "❌") \(check.name): \(check.reason)")
            }
        }
        if !blockingIssues.isEmpty {
            lines.append("阻断问题:")
            for issue in blockingIssues { lines.append("- \(issue)") }
        }
        if !evidence.isEmpty {
            lines.append("证据:")
            for item in evidence { lines.append("- \(item)") }
        }
        if let needsUser, !needsUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("需要用户: \(needsUser)")
        }
        if let interaction = humanInteraction?.normalized {
            lines.append("等待人机协作: \(interaction.prompt)")
        }
        return lines.joined(separator: "\n")
    }

    /// 主对话使用的紧凑验收摘要。JSON verdict 是控制面协议,不能直接暴露给用户;
    /// 这里把字段转换成可扫描的 Markdown,同时限制单项长度,避免一条证据撑满整个气泡。
    var conversationSummary: String {
        var sections: [String] = []
        let cleanedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedSummary.isEmpty {
            sections.append(cleanedSummary)
        }
        if !checks.isEmpty {
            var lines = ["**验收明细**"]
            for check in checks.prefix(6) {
                let reason = Self.compact(check.reason, limit: 180)
                let suffix = reason.isEmpty ? "" : "：\(reason)"
                lines.append("- \(check.passed ? "✅" : "❌") **\(check.name)**\(suffix)")
            }
            if checks.count > 6 {
                lines.append("- 其余 \(checks.count - 6) 项详见任务执行记录")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if !blockingIssues.isEmpty {
            sections.append((["**需要修正**"] + blockingIssues.prefix(6).map {
                "- \(Self.compact($0, limit: 180))"
            }).joined(separator: "\n"))
        }
        if !evidence.isEmpty {
            sections.append((["**核验依据**"] + evidence.prefix(3).map {
                "- \(Self.compact($0, limit: 220))"
            }).joined(separator: "\n"))
        }
        if let needsUser, !needsUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("**需要你确认**：\(Self.compact(needsUser, limit: 180))")
        }
        if let interaction = humanInteraction?.normalized {
            sections.append("**等待你完成**：\(Self.compact(interaction.prompt, limit: 180))")
        }
        return sections.joined(separator: "\n\n")
    }

    static let outputContract = """
    只输出一个 JSON 对象,不要 markdown,不要代码围栏,不要额外解释。格式:
    {
      "status": "passed | failed | needs_human_interaction",
      "passed": true,
      "confidence": 0.0,
      "summary": "一句话总结验收结论",
      "checks": [
        {"name": "真实性", "passed": true, "reason": "证据说明"},
        {"name": "完整性", "passed": false, "reason": "缺少什么"}
      ],
      "blockingIssues": ["未通过时列阻断问题;通过时为空数组"],
      "evidence": ["你实际核验过的文件、命令、输出或事实"],
      "needsUser": null,
      "human_interaction": null
    }
    正常验收时 status=passed/failed，并填写对应 passed 布尔值；passed 只有在所有必要检查项都通过时才能为 true，任何阻断问题都必须让 status=failed、passed=false。
    如果验收过程中发现必须由人参与扫码、外部登录、实体操作、选文件、确认或完成其它交互，不要把它当通过或不通过：填 status=needs_human_interaction、human_interaction={kind,title,prompt,payload,options,completion_probe,resume_token,source}，passed 可填 null，blockingIssues 可为空。任何 planner、worker、checker、工具或外部监视器都遵循同一人机交互协议。OAuth/凭据授权仍由主流程的 OAuth 字段处理，不要在这里伪造授权卡。
    """

    static func parse(_ raw: String) -> LingShuCheckerVerdict? {
        let stripped = LingShuReasoningText.stripThinkTags(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = firstJSONObject(in: stripped),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let humanInteraction = LingShuHumanInteractionRequest.parse(object["humanInteraction"] ?? object["human_interaction"])
        let status = (string(object["status"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let passed: Bool
        if let explicit = object["passed"] as? Bool {
            passed = explicit
        } else if ["passed", "pass", "ok"].contains(status) {
            passed = true
        } else if ["failed", "fail", "rejected", "needs_human_interaction", "human_interaction", "waiting_for_human"].contains(status)
                    || humanInteraction != nil {
            passed = false
        } else {
            return nil
        }

        return LingShuCheckerVerdict(
            passed: passed,
            confidence: number(object["confidence"]),
            summary: string(object["summary"]) ?? "",
            checks: checks(object["checks"]),
            blockingIssues: stringArray(object["blockingIssues"] ?? object["blocking_issues"]),
            evidence: stringArray(object["evidence"]),
            needsUser: nullableString(object["needsUser"] ?? object["needs_user"]),
            humanInteraction: humanInteraction
        )
    }

    private static func firstJSONObject(in text: String) -> String? {
        let withoutFence = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = withoutFence.firstIndex(of: "{"),
              let end = withoutFence.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(withoutFence[start...end])
    }

    private static func checks(_ value: Any?) -> [Check] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            let name = string(object["name"]) ?? string(object["criterion"]) ?? "检查项"
            let reason = string(object["reason"]) ?? string(object["evidence"]) ?? ""
            let status = (string(object["status"]) ?? "").lowercased()
            let passed = object["passed"] as? Bool ?? ["pass", "passed", "ok"].contains(status)
            return Check(name: name, passed: passed, reason: reason)
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { string($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let s = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return [s]
        }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func nullableString(_ value: Any?) -> String? {
        guard !(value is NSNull) else { return nil }
        return string(value)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let flattened = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(max(1, limit - 1))) + "…"
    }
}
