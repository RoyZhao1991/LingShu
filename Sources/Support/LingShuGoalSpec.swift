import Foundation

/// 通用中枢 P1·**目标认知(GoalSpec)**(纯类型 + 容错解析,可单测)。
///
/// 把用户一条请求解析成结构化目标规格——这是"理解目标"的载体,后续(P2 缺口分析 / P3 通用验收 / P4 经验沉淀)
/// 都引用它。模型产出(零领域分支),解析容错(LLM 常带 markdown 围栏/夹叙)。
/// **P1a 仅观察态**:入口产出并落痕,绝不改变执行;P1b+ 才让循环/验收/记忆真正消费它。
enum LingShuGoalKind: String, Codable, Sendable, Equatable {
    case task          // 要产出交付物 / 真实动作
    case interaction   // 演示 / 答疑 / 陪聊(无交付物)
    case question      // 纯信息提问
    case unknown
}

struct LingShuGoalSpec: Codable, Sendable, Equatable {
    var objective: String          // 一句话:模型重述用户真正想要的结果
    var kind: LingShuGoalKind      // 任务 / 互动 / 疑问
    var constraints: [String]      // 必须满足的条件(格式/时限/工具/环境)
    var boundaries: [String]       // 明确不该做 / 越界即停
    var risks: [String]            // 隐私/资金/账号/不可逆/对外发布/物理动作等风险点
    var successCriteria: [String]  // 怎样算真正达成 = 验收依据
    var openQuestions: [String]    // 信息不足、需先问用户澄清的

    init(objective: String, kind: LingShuGoalKind = .unknown, constraints: [String] = [],
         boundaries: [String] = [], risks: [String] = [], successCriteria: [String] = [],
         openQuestions: [String] = []) {
        self.objective = objective; self.kind = kind; self.constraints = constraints
        self.boundaries = boundaries; self.risks = risks
        self.successCriteria = successCriteria; self.openQuestions = openQuestions
    }

    /// P1b·**执行引导**(注入正在执行的会话,让模型据结构化目标推进、别跑偏)。合并到既有 guidance 之上。
    /// **默认自洽范式(2026-06-27 修过度追问)**:有【待澄清】点时,**默认带合理假设直接做、把假设写进交付**,
    /// 绝不为可默认的细节停下来 ask_user;只有【硬前提】(凭据/授权/付费/物理设备/不可逆危险)缺了才问。
    func executionGuidance(base: String?) -> String {
        var block = "【本次目标(已结构化理解,据此推进,别跑偏)】\n\(summary)"
        if !openQuestions.isEmpty {
            block += "\n上面的【待澄清】点 → **绝大多数都能带合理默认直接做**(让用户在产物里自调、或挑个常见默认),做完把假设写进交付说明,**别停下来问**;**只有缺了就真做不动的硬前提(登录凭据/API授权/付费确认/物理设备/不可逆危险)才用 ask_user**。"
        }
        guard let b = base?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return block }
        return b + "\n\n" + block
    }

    /// P1b·**验收成功标准块**(给独立验收官,完整性维度据此逐条核对是否达成)。无成功标准则空串(不加压)。
    var acceptanceCriteriaBlock: String {
        guard !successCriteria.isEmpty else { return "" }
        return "【本次目标的成功标准(用户目标拆解,完整性维度据此核对是否真达成)】\n"
            + successCriteria.map { "- \($0)" }.joined(separator: "\n")
    }

    /// 人可读摘要(落 trace / 任务记录用)。
    var summary: String {
        var lines = ["目标:\(objective)(\(kind.rawValue))"]
        if !constraints.isEmpty { lines.append("约束:" + constraints.joined(separator: ";")) }
        if !boundaries.isEmpty { lines.append("边界:" + boundaries.joined(separator: ";")) }
        if !risks.isEmpty { lines.append("风险:" + risks.joined(separator: ";")) }
        if !successCriteria.isEmpty { lines.append("成功标准:" + successCriteria.joined(separator: ";")) }
        if !openQuestions.isEmpty { lines.append("待澄清:" + openQuestions.joined(separator: ";")) }
        return lines.joined(separator: "\n")
    }
}

enum LingShuGoalSpecParser {
    /// 给模型的解析指令:只输出一个 JSON 目标规格(无解释、无 markdown 围栏)。
    static let systemPrompt = """
    你是目标解析器。把用户这条请求解析成一个 JSON 目标规格,**只输出 JSON 本身**(不要解释、不要 markdown 围栏)。字段:
    - objective: 一句话重述用户真正想要的结果(不是复述原话,是抓住意图)
    - kind: 三选一 —— "task"(要你做出交付物/真实动作)、"interaction"(演示/答疑/陪聊,无交付物)、"question"(纯信息提问)
    - constraints: 必须满足的条件数组(格式/时限/指定工具/环境约束),无则 []
    - boundaries: 明确不该做、越界即停的数组,无则 []
    - risks: 涉及隐私/资金/账号/不可逆/对外发布/物理动作等风险点数组,无则 []
    - success_criteria: 怎样算真正达成(验收依据)数组,无则 []
    - open_questions: 信息不足、需要先问用户澄清的数组,无则 []
    """

    /// 容错解析:剥 markdown 围栏 + 取首个 {...} + JSON 解析;无 objective 视为解析失败(返回 nil)。
    static func parse(_ raw: String) -> LingShuGoalSpec? {
        guard let obj = extractJSONObject(raw) else { return nil }
        let objective = ((obj["objective"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return nil }
        func arr(_ key: String) -> [String] {
            ((obj[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let kind = LingShuGoalKind(rawValue: ((obj["kind"] as? String) ?? "").lowercased()) ?? .unknown
        return LingShuGoalSpec(
            objective: objective, kind: kind,
            constraints: arr("constraints"), boundaries: arr("boundaries"), risks: arr("risks"),
            successCriteria: arr("success_criteria"), openQuestions: arr("open_questions")
        )
    }

    /// 从可能夹叙/带围栏的文本里取出第一个完整 JSON 对象。纯逻辑。
    static func extractJSONObject(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
