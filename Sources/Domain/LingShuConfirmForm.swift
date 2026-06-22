import Foundation

/// 多项确认表单(用户定调 2026-06-21):灵枢一次需要主人确认**多个事项**时,不应flatten成一个单选卡,
/// 而是**每个事项一行、各带自己的选择菜单**,且每个菜单**末行恒是「其他(自行输入)」**让主人填自由值。
/// 对应工具 `ask_form`;UI 渲染 `LingShuFormCard`;主人填完一次性提交,灵枢拿到全部字段答案继续。
struct LingShuConfirmFormField: Codable, Equatable, Sendable, Identifiable {
    var key: String          // 字段标识(回传给模型时用,如 "city" / "pay")
    var question: String     // 问题正文
    var options: [String]    // 预设可选项(UI 末尾自动追加「其他(自行输入)」,不必自己加)
    var id: String { key }

    init(key: String, question: String, options: [String]) {
        self.key = key
        self.question = question
        self.options = options
    }
}

struct LingShuConfirmForm: Codable, Equatable, Sendable {
    var title: String
    var fields: [LingShuConfirmFormField]

    /// 末行自由输入项的固定标识(UI 选它即展开文本框)。
    static let otherOptionLabel = "其他(自行输入)"

    /// 至少要有 1 个有效字段才算合法表单。
    var sanitized: LingShuConfirmForm? {
        let valid = fields.filter { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.key.isEmpty }
        guard !valid.isEmpty else { return nil }
        return LingShuConfirmForm(title: title, fields: valid)
    }

    /// 解析模型给的 JSON 信封 → 表单。容错别名:fields/items;每项 key/question(/label/q)/options(/choices)。
    static func parse(_ json: String) -> LingShuConfirmForm? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw = (obj["fields"] as? [[String: Any]]) ?? (obj["items"] as? [[String: Any]]) ?? []
        var fields: [LingShuConfirmFormField] = []
        for (i, f) in raw.enumerated() {
            let question = ((f["question"] as? String) ?? (f["label"] as? String) ?? (f["q"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { continue }
            let key = ((f["key"] as? String) ?? "f\(i)").trimmingCharacters(in: .whitespacesAndNewlines)
            let options = ((f["options"] as? [String]) ?? (f["choices"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            fields.append(LingShuConfirmFormField(key: key, question: question, options: options))
        }
        let title = (obj["title"] as? String) ?? "需要你确认几件事"
        return LingShuConfirmForm(title: title, fields: fields).sanitized
    }

    /// 把主人填好的答案(key→值)拼成给模型的可读回传文本(按字段顺序,带问题)。
    func formatAnswers(_ answers: [String: String]) -> String {
        let lines = fields.map { field -> String in
            let v = (answers[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(field.question) → \(v.isEmpty ? "(未填)" : v)"
        }
        return "主人已确认以下事项:\n" + lines.joined(separator: "\n")
    }
}
