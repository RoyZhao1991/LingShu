import Foundation

enum LingShuAgentFailureCategory: String, Sendable, Equatable {
    case unavailableAuth = "unavailable_auth"
    case unavailableQuota = "unavailable_quota"
    case unavailableInstall = "unavailable_install"
    case unavailableDependency = "unavailable_dependency"
    case temporaryUnavailable = "temporary_unavailable"
    case taskFailed = "task_failed"
    case timeout
    case cancelled
    case unknown

    var impliesPluginUnavailable: Bool {
        switch self {
        case .unavailableAuth, .unavailableQuota, .unavailableInstall, .unavailableDependency:
            return true
        case .temporaryUnavailable, .taskFailed, .timeout, .cancelled, .unknown:
            return false
        }
    }
}

struct LingShuAgentFailureDiagnosis: Sendable, Equatable {
    let category: LingShuAgentFailureCategory
    let confidence: LingShuGoalReferenceConfidence
    let reason: String
    let userMessage: String
    let retryAdvice: String
    let markPluginUnavailable: Bool

    var traceSummary: String {
        [
            "category=\(category.rawValue)",
            "confidence=\(confidence.rawValue)",
            "markPluginUnavailable=\(markPluginUnavailable)",
            "reason=\(reason)"
        ].joined(separator: "; ")
    }

    static func parse(_ raw: String) -> LingShuAgentFailureDiagnosis? {
        guard let obj = LingShuGoalSpecParser.extractJSONObject(raw) else { return nil }
        let category = LingShuAgentFailureCategory(
            rawValue: ((obj["category"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
        ) ?? .unknown
        let confidence = LingShuGoalSpecParser.parseReferenceConfidence(obj["confidence"])
        let reason = clippedScalar(obj["reason"], fallback: category.defaultReason, maxLength: 48)
        let userMessage = clippedScalar(obj["user_message"], fallback: "", maxLength: 220)
        let retryAdvice = clippedScalar(obj["retry_advice"], fallback: "", maxLength: 160)
        let requestedMark = boolValue(obj["mark_plugin_unavailable"])
        let mark = requestedMark && category.impliesPluginUnavailable && confidence != .low
        return .init(
            category: category,
            confidence: confidence,
            reason: reason,
            userMessage: userMessage,
            retryAdvice: retryAdvice,
            markPluginUnavailable: mark
        )
    }

    static func fallbackMessage(agentName: String, diagnosis: LingShuAgentFailureDiagnosis, rawFailure: String) -> String {
        let message = diagnosis.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        let reason = diagnosis.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        switch diagnosis.category {
        case .taskFailed:
            return "\(agentName) 已启动但未完成这次任务:\(reason.isEmpty ? String(rawFailure.prefix(220)) : reason)。"
        case .temporaryUnavailable:
            return "\(agentName) 插件暂时不可用:\(reason.isEmpty ? "外部服务临时异常" : reason)。稍后可重试。"
        case .timeout:
            return "\(agentName) 本次运行超时:\(reason.isEmpty ? "长时间无输出" : reason)。"
        case .cancelled:
            return "\(agentName) 本次运行已取消。"
        case .unknown:
            return "\(agentName) 本次运行失败,原因尚未能可靠归类:\(String(rawFailure.prefix(220)))"
        case .unavailableAuth, .unavailableQuota, .unavailableInstall, .unavailableDependency:
            return LingShuAgentPluginStore.unavailableMessage(agentName: agentName, reason: reason.isEmpty ? diagnosis.category.defaultReason : reason)
        }
    }

    static func sanitizedEvidence(_ text: String, maxLength: Int = 2400) -> String {
        var value = text
        let prefixPatterns = [
            #"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9._\-]{8,}"#,
            #"(?i)(api[_-]?key["'=:\s]+)[A-Za-z0-9._\-]{8,}"#,
            #"(?i)(token["'=:\s]+)[A-Za-z0-9._\-]{8,}"#
        ]
        for pattern in prefixPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (value as NSString).length)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1***")
        }
        let wholeSecretPatterns = [
            #"\b(sk-[A-Za-z0-9_\-]{12,})\b"#,
            #"\b(ghp_[A-Za-z0-9_]{12,})\b"#,
            #"\b(xox[baprs]-[A-Za-z0-9\-]{12,})\b"#
        ]
        for pattern in wholeSecretPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (value as NSString).length)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "***")
        }
        if value.count > maxLength { return String(value.prefix(maxLength)) + "…（节选）" }
        return value
    }

    private static func clippedScalar(_ raw: Any?, fallback: String, maxLength: Int) -> String {
        let value: String
        switch raw {
        case let s as String:
            value = s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { value = n.boolValue ? "true" : "false" }
            else { value = n.stringValue }
        default:
            value = fallback
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) : trimmed
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        switch raw {
        case let b as Bool:
            return b
        case let n as NSNumber:
            return n.boolValue
        case let s as String:
            return ["true", "yes", "1"].contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }
}

private extension LingShuAgentFailureCategory {
    var defaultReason: String {
        switch self {
        case .unavailableAuth: return "认证不可用"
        case .unavailableQuota: return "额度不可用"
        case .unavailableInstall: return "插件安装不可用"
        case .unavailableDependency: return "运行依赖不可用"
        case .temporaryUnavailable: return "外部服务临时不可用"
        case .taskFailed: return "任务执行失败"
        case .timeout: return "运行超时"
        case .cancelled: return "已取消"
        case .unknown: return "未知失败"
        }
    }
}
