import Foundation

/// 大脑输出的流程协议。
///
/// 普通文本只用于展示;只有当模型输出**严格 JSON 对象**时,流程层才读取这些字段。
/// 这样 OAuth/token/授权/无法完成 等自然语言词汇不会误伤流程。
struct LingShuStructuredModelOutput: Sendable, Equatable {
    static let finalAnswerContract = """

【最终回复结构协议】
当你准备对用户收尾回复、询问用户、声明部分完成、声明阻断或说明需要补齐能力时，最终输出必须是一个完整 JSON 对象，不要输出 Markdown、代码块或 JSON 外的解释文本。界面只展示 reply；流程只读取结构字段。
固定格式：
{
  "reply": "面向用户展示/朗读的一段自然语言。不要把 JSON、内部工具名、占位符或日志写进这里。",
  "completion": {
    "status": "ok | partial | blocked | waiting_for_user | needs_acquisition",
    "reason": "给流程层看的简短原因；普通问答完成填 ok。",
    "needs_user": false
  },
  "user_input": null,
  "inability": null,
  "OAuth": null
}
OAuth 是唯一能触发授权/确认窗口的字段。只有确实需要用户授权、凭据、账号、付费、物理确认等前提时，OAuth 才能填对象；普通解释 OAuth/token/授权概念时必须填 null。
缺少非授权前提、需要用户补充信息或需要用户选择时，填 user_input 对象；否则填 null。
承认缺能力、缺前提、部分完成、等待用户或需要自我补齐能力，都必须通过 completion.status / completion.needs_user / user_input / inability / OAuth 表达，不允许只写在 reply 文本里。
"""

    struct Completion: Sendable, Equatable {
        enum Status: String, Sendable, Equatable {
            case ok
            case partial
            case blocked
            case waitingForUser
            case needsAcquisition
        }

        var status: Status
        var reason: String
        var needsUser: Bool
    }

    struct UserInputRequest: Sendable, Equatable {
        var required: Bool
        var question: String
        var reason: String
        var options: [LingShuRouteChoiceOption]

        var normalized: UserInputRequest? {
            guard required else { return nil }
            var copy = self
            if copy.question.isEmpty { copy.question = copy.reason }
            guard !copy.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if copy.options.isEmpty {
                copy.options = [
                    .init(label: "我已补充，继续", detail: "我已经提供了缺少的信息或前提，继续当前任务。"),
                    .init(label: "先停在这里", detail: "当前任务先暂停，不继续推进。"),
                    .init(label: "改用替代方案", detail: "不等待该前提，尝试可逆的替代路径。")
                ]
            }
            return copy
        }

        var choicePrompt: LingShuRouteChoicePrompt? {
            guard let normalized else { return nil }
            return LingShuRouteChoicePrompt(question: normalized.question, options: normalized.options).sanitized
        }

        static func parse(_ raw: Any?) -> UserInputRequest? {
            guard let raw else { return nil }
            if let required = raw as? Bool {
                return required ? .init(required: true, question: "这一步需要你补充信息后才能继续。", reason: "", options: []) : nil
            }
            guard let obj = raw as? [String: Any] else { return nil }
            let required = (obj["required"] as? Bool)
                ?? (obj["needs_user"] as? Bool)
                ?? (obj["need_user"] as? Bool)
                ?? (obj["requires_user"] as? Bool)
                ?? false
            let options = ((obj["options"] as? [Any]) ?? []).compactMap(LingShuOAuthAuthorizationOption.parse)
                .map { LingShuRouteChoiceOption(label: $0.label, detail: $0.detail) }
            let request = UserInputRequest(
                required: required,
                question: ((obj["question"] as? String)
                           ?? (obj["prompt"] as? String)
                           ?? (obj["message"] as? String)
                           ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                reason: ((obj["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                options: options
            )
            return request.normalized
        }
    }

    struct Inability: Sendable, Equatable {
        var reason: String
        var missing: [String]

        static func parse(_ raw: Any?) -> Inability? {
            guard let raw else { return nil }
            if let flag = raw as? Bool { return flag ? .init(reason: "模型声明当前无法完成。", missing: []) : nil }
            guard let obj = raw as? [String: Any] else { return nil }
            let reason = ((obj["reason"] as? String)
                          ?? (obj["message"] as? String)
                          ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let missing = ((obj["missing"] as? [String])
                           ?? (obj["missing_capabilities"] as? [String])
                           ?? (obj["missingCapabilities"] as? [String])
                           ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !reason.isEmpty || !missing.isEmpty else { return nil }
            return .init(reason: reason, missing: missing)
        }
    }

    var reply: String
    var completion: Completion?
    var userInput: UserInputRequest?
    var inability: Inability?
    var OAuth: LingShuOAuthAuthorizationRequest?

    var visibleText: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }
    var declaresUserBlock: Bool {
        (OAuth?.normalized != nil)
        || (userInput?.normalized != nil)
        || completion?.needsUser == true
        || completion?.status == .waitingForUser
    }
    var declaresPartial: Bool { completion?.status == .partial }
    var declaresBlocked: Bool { completion?.status == .blocked || inability != nil }
    var declaresNeedsAcquisition: Bool { completion?.status == .needsAcquisition }
    var declaresIncomplete: Bool {
        declaresUserBlock || declaresPartial || declaresBlocked || declaresNeedsAcquisition
    }

    static func visibleText(from raw: String) -> String {
        guard let parsed = parse(raw), !parsed.visibleText.isEmpty else { return raw }
        return parsed.visibleText
    }

    static func parse(_ raw: String) -> LingShuStructuredModelOutput? {
        guard let obj = strictJSONObject(raw) else { return nil }
        let hasKnownKey = obj.keys.contains("reply")
            || obj.keys.contains("message")
            || obj.keys.contains("completion")
            || obj.keys.contains("userInput")
            || obj.keys.contains("user_input")
            || obj.keys.contains("missingPrerequisite")
            || obj.keys.contains("missing_prerequisite")
            || obj.keys.contains("prerequisite")
            || obj.keys.contains("inability")
            || obj.keys.contains("OAuth")
            || obj.keys.contains("oauth")
        guard hasKnownKey else { return nil }
        let reply = ((obj["reply"] as? String) ?? (obj["message"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = parseCompletion(obj["completion"])
        let userInput = UserInputRequest.parse(
            obj["userInput"]
            ?? obj["user_input"]
            ?? obj["missingPrerequisite"]
            ?? obj["missing_prerequisite"]
            ?? obj["prerequisite"]
        )
        let inability = Inability.parse(obj["inability"])
        let oauth = LingShuOAuthAuthorizationRequest.parse(obj["OAuth"] ?? obj["oauth"])
        guard !reply.isEmpty || completion != nil || userInput != nil || inability != nil || oauth != nil else { return nil }
        return .init(reply: reply, completion: completion, userInput: userInput, inability: inability, OAuth: oauth)
    }

    private static func parseCompletion(_ raw: Any?) -> Completion? {
        guard let obj = raw as? [String: Any] else { return nil }
        let rawStatus = ((obj["status"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let status: Completion.Status
        switch rawStatus {
        case "ok", "done", "completed", "complete", "success":
            status = .ok
        case "partial", "partially_done", "partially_completed":
            status = .partial
        case "blocked", "failed", "cannot_complete", "incomplete":
            status = .blocked
        case "waiting_for_user", "wait_user", "needs_user", "need_user":
            status = .waitingForUser
        case "needs_acquisition", "need_acquisition", "acquire_capability":
            status = .needsAcquisition
        default:
            return nil
        }
        let reason = ((obj["reason"] as? String) ?? (obj["message"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needsUser = (obj["needs_user"] as? Bool)
            ?? (obj["need_user"] as? Bool)
            ?? (obj["requires_user"] as? Bool)
            ?? (status == .waitingForUser)
        return .init(status: status, reason: reason, needsUser: needsUser)
    }

    /// 只接受“整段就是 JSON 对象”的输出,不从夹杂解释的文本里抠 JSON。
    private static func strictJSONObject(_ raw: String) -> [String: Any]? {
        var text = LingShuReasoningText.stripThinkTags(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let firstLine = lines.first.map(String.init) ?? ""
            let lastLine = lines.last.map(String.init) ?? ""
            if lines.count >= 2,
               firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("```"),
               lastLine.trimmingCharacters(in: .whitespaces) == "```" {
                text = lines.dropFirst().dropLast().map(String.init).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return nil }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
