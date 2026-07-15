import Foundation

/// GoalSpec 生成的模型无关策略。
///
/// 不根据模型名称分支：超时只取决于输入规模；结构化提交能力按真实协议响应记忆，
/// 切换 provider / endpoint / model / protocol 后自然形成新的能力键并重新探测。
enum LingShuGoalSpecGenerationPolicy {
    static let maximumAttempts = 3

    /// 输入越大，给模型的首轮时间越长。三档仍有上限，避免故障通道无限占住入口。
    static func timeouts(for payload: String) -> [TimeInterval] {
        let estimatedTokens = LingShuTokenEstimator.estimate(payload) + 800
        let first = min(75.0, max(30.0, ceil(20.0 + Double(estimatedTokens) / 400.0)))
        let second = min(120.0, max(first + 15.0, ceil(first * 1.35)))
        let third = min(180.0, max(second + 20.0, ceil(first * 1.8)))
        return [first, second, third]
    }
}

/// 结构化工具提交能力的运行时记忆。只在服务端明确拒绝 tools/function calling 时标记，
/// 模型偶尔没有调用工具不等同于“不支持”，不会因此污染后续结果。
enum LingShuStructuredGoalSpecCapability {
    private static let unsupportedDefaultsKey = "lingshu.goalSpec.toolSubmissionUnsupported.v1"
    private static let unsupportedTTL: TimeInterval = 7 * 24 * 60 * 60

    static func shouldAttemptToolSubmission(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        format: LingShuModelGatewayRequestFormat,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        switch format {
        case .chatCompletions, .anthropicMessages:
            break
        case .responses, .hostAdapter:
            return false
        }
        return !isMarkedToolSubmissionUnsupported(
            provider: provider,
            model: model,
            endpoint: endpoint,
            protocolName: protocolName,
            defaults: defaults,
            now: now
        )
    }

    static func isMarkedToolSubmissionUnsupported(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        let key = capabilityKey(provider: provider, model: model, endpoint: endpoint, protocolName: protocolName)
        guard let markedAt = unsupportedEntries(defaults: defaults)[key] else { return false }
        if now.timeIntervalSince1970 - markedAt > unsupportedTTL {
            var entries = unsupportedEntries(defaults: defaults)
            entries[key] = nil
            defaults.set(entries, forKey: unsupportedDefaultsKey)
            return false
        }
        return true
    }

    static func markToolSubmissionUnsupported(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        var entries = unsupportedEntries(defaults: defaults)
        entries[capabilityKey(provider: provider, model: model, endpoint: endpoint, protocolName: protocolName)] = now.timeIntervalSince1970
        defaults.set(entries, forKey: unsupportedDefaultsKey)
    }

    /// 只有“请求无效 + 明确提到工具/函数字段不受支持”才形成长期能力结论。
    static func explicitlyRejectsToolSubmission(_ encodedReason: String) -> Bool {
        guard let failure = LingShuModelServiceFailure.decodeReason(encodedReason),
              failure.kind == .requestInvalid else { return false }
        let text = failure.detail.lowercased()
        let mentionsToolContract = [
            "tools", "tool_choice", "tool choice", "tool_use", "tool use",
            "function_call", "function call", "function calling", "函数调用", "工具调用"
        ].contains { text.contains($0) }
        let explicitlyUnsupported = [
            "unsupported", "not support", "does not support", "unknown field", "unknown parameter",
            "unrecognized", "not allowed", "invalid parameter", "extra fields", "不支持", "未知字段", "非法参数", "无效参数"
        ].contains { text.contains($0) }
        return mentionsToolContract && explicitlyUnsupported
    }

    private static func unsupportedEntries(defaults: UserDefaults) -> [String: TimeInterval] {
        guard let raw = defaults.dictionary(forKey: unsupportedDefaultsKey) else { return [:] }
        return raw.reduce(into: [:]) { result, item in
            if let value = item.value as? NSNumber {
                result[item.key] = value.doubleValue
            }
        }
    }

    private static func capabilityKey(provider: String, model: String, endpoint: String, protocolName: String) -> String {
        [provider, endpoint, model, protocolName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }
}

actor LingShuGoalSpecSubmissionBox {
    struct Snapshot: Sendable {
        let accepted: LingShuGoalSpec?
        let raw: String?
        let issue: String?
    }

    private let allowUnresolvedReference: Bool
    private var accepted: LingShuGoalSpec?
    private var raw: String?
    private var issue: String?

    init(allowUnresolvedReference: Bool) {
        self.allowUnresolvedReference = allowUnresolvedReference
    }

    func submit(_ argumentsJSON: String) -> String {
        raw = argumentsJSON
        guard let spec = LingShuGoalSpecParser.parse(argumentsJSON) else {
            let parseIssue = "submit_goal_spec 参数不是可解析的 GoalSpec JSON"
            issue = parseIssue
            return "GOAL_SPEC_REJECTED: \(parseIssue)"
        }
        if let readinessIssue = LingShuGoalSpecParser.executionReadinessIssue(
            spec,
            allowUnresolvedReference: allowUnresolvedReference
        ) {
            issue = readinessIssue
            return "GOAL_SPEC_REJECTED: \(readinessIssue)"
        }
        accepted = spec
        issue = nil
        return "GOAL_SPEC_ACCEPTED"
    }

    func snapshot() -> Snapshot {
        Snapshot(accepted: accepted, raw: raw, issue: issue)
    }
}

/// 所有支持原生工具调用的通道共用同一份 Schema；这里没有任何 provider/model 名称判断。
enum LingShuGoalSpecToolContract {
    static let toolName = "submit_goal_spec"

    static let parametersJSON = """
    {
      "type":"object",
      "properties":{
        "objective":{"type":"string","description":"一句话重述用户真正要达成的结果"},
        "kind":{"type":"string","enum":["task","interaction","question"]},
        "output_mode":{"type":"string","enum":["chat_reply","artifact","visible_interaction","external_action"]},
        "reference_scope":{"type":"string","enum":["current_input","default_anchor","candidate_background","visible_context","task_thread","memory","unknown"]},
        "reference_explicit":{"type":"boolean"},
        "reference_confidence":{"type":"string","enum":["high","medium","low","unknown"]},
        "reference_evidence":{"type":"array","items":{"type":"string"}},
        "constraints":{"type":"array","items":{"type":"string"}},
        "boundaries":{"type":"array","items":{"type":"string"}},
        "risks":{"type":"array","items":{"type":"string"}},
        "success_criteria":{"type":"array","items":{"type":"string"}},
        "open_questions":{"type":"array","items":{"type":"string"}}
      },
      "required":["objective","kind","output_mode","reference_scope","reference_explicit","reference_confidence","reference_evidence","constraints","boundaries","risks","success_criteria","open_questions"]
    }
    """

    static func makeTool(box: LingShuGoalSpecSubmissionBox) -> LingShuAgentTool {
        LingShuAgentTool(
            name: toolName,
            description: "提交最终、完整、可执行的 GoalSpec。必须严格使用参数 Schema 中的枚举和数组类型。",
            parametersJSON: parametersJSON
        ) { argumentsJSON in
            await box.submit(argumentsJSON)
        }
    }
}
