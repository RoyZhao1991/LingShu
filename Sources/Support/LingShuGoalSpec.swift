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

/// 目标的**输出/交付形态**。这是分诊以后给下游验收、完成闸、可视交付层看的结构字段:
/// 同样是 task,也可能只是“检查后只回复一句”,不能被交付层强行改造成文件/预览任务。
enum LingShuOutputMode: String, Codable, Sendable, Equatable {
    case unspecified
    case chatReply = "chat_reply"                  // 最终交付就是一条聊天回复
    case artifact                                 // 需要落文件/产物
    case visibleInteraction = "visible_interaction"// 需要打开/演示/讲解/播报等可感知交互
    case externalAction = "external_action"        // 需要改变外部系统/设备/网络/账号状态
}

/// 第④站目标认知的**引用范围**。
/// 作用:把“这条输入到底在接谁”从自然语言变成 typed 字段,避免下游靠关键词/文本猜。
enum LingShuGoalReferenceScope: String, Codable, Sendable, Equatable {
    case currentInput = "current_input"             // 当前输入自身已经完整表达目标
    case defaultAnchor = "default_anchor"           // 省略/续接/指代,默认承接最近完成回合
    case candidateBackground = "candidate_background" // 明确指向上下文候选(旧材料/旧任务/旧话题)
    case visibleContext = "visible_context"         // 明确指向当前可见材料/屏幕/预览
    case taskThread = "task_thread"                 // 明确指向某个隔离任务线程
    case memory = "memory"                          // 明确要求回溯长期记忆
    case unknown

    var escapesDefaultAnchor: Bool {
        switch self {
        case .candidateBackground, .visibleContext, .taskThread, .memory:
            return true
        case .currentInput, .defaultAnchor, .unknown:
            return false
        }
    }
}

/// GoalSpec 对“当前输入到底接谁”的置信度。低/中置信会触发历史检索兜底,
/// 让模型先主动找证据再最终定目标。
enum LingShuGoalReferenceConfidence: String, Codable, Sendable, Equatable {
    case high
    case medium
    case low
    case unknown
}

struct LingShuGoalSpec: Codable, Sendable, Equatable {
    var objective: String          // 一句话:模型重述用户真正想要的结果
    var kind: LingShuGoalKind      // 任务 / 互动 / 疑问
    var outputMode: LingShuOutputMode // 输出形态:聊天回复 / 产物 / 可视交互 / 外部动作
    var referenceScope: LingShuGoalReferenceScope // 本目标引用的上下文范围
    var referenceEvidence: [String] // 支撑引用范围的原文证据(短引用)
    var referenceExplicit: Bool     // 是否由当前输入显式指向非默认候选
    var referenceConfidence: LingShuGoalReferenceConfidence // 引用归属置信度
    var constraints: [String]      // 必须满足的条件(格式/时限/工具/环境)
    var boundaries: [String]       // 明确不该做 / 越界即停
    var risks: [String]            // 隐私/资金/账号/不可逆/对外发布/物理动作等风险点
    var successCriteria: [String]  // 怎样算真正达成 = 验收依据
    var openQuestions: [String]    // 信息不足、需先问用户澄清的

    init(objective: String, kind: LingShuGoalKind = .unknown, constraints: [String] = [],
         boundaries: [String] = [], risks: [String] = [], successCriteria: [String] = [],
         openQuestions: [String] = [], outputMode: LingShuOutputMode = .unspecified,
         referenceScope: LingShuGoalReferenceScope = .unknown,
         referenceEvidence: [String] = [], referenceExplicit: Bool = false,
         referenceConfidence: LingShuGoalReferenceConfidence = .unknown) {
        self.objective = objective; self.kind = kind; self.outputMode = outputMode
        self.referenceScope = referenceScope; self.referenceEvidence = referenceEvidence; self.referenceExplicit = referenceExplicit
        self.referenceConfidence = referenceConfidence
        self.constraints = constraints
        self.boundaries = boundaries; self.risks = risks
        self.successCriteria = successCriteria; self.openQuestions = openQuestions
    }

    private enum CodingKeys: String, CodingKey {
        case objective, kind, outputMode, referenceScope, referenceEvidence, referenceExplicit, referenceConfidence
        case constraints, boundaries, risks, successCriteria, openQuestions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objective = try container.decode(String.self, forKey: .objective)
        kind = try container.decodeIfPresent(LingShuGoalKind.self, forKey: .kind) ?? .unknown
        outputMode = try container.decodeIfPresent(LingShuOutputMode.self, forKey: .outputMode) ?? .unspecified
        referenceScope = try container.decodeIfPresent(LingShuGoalReferenceScope.self, forKey: .referenceScope) ?? .unknown
        referenceEvidence = try container.decodeIfPresent([String].self, forKey: .referenceEvidence) ?? []
        referenceExplicit = try container.decodeIfPresent(Bool.self, forKey: .referenceExplicit) ?? false
        referenceConfidence = try container.decodeIfPresent(LingShuGoalReferenceConfidence.self, forKey: .referenceConfidence) ?? .unknown
        constraints = try container.decodeIfPresent([String].self, forKey: .constraints) ?? []
        boundaries = try container.decodeIfPresent([String].self, forKey: .boundaries) ?? []
        risks = try container.decodeIfPresent([String].self, forKey: .risks) ?? []
        successCriteria = try container.decodeIfPresent([String].self, forKey: .successCriteria) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objective, forKey: .objective)
        try container.encode(kind, forKey: .kind)
        try container.encode(outputMode, forKey: .outputMode)
        try container.encode(referenceScope, forKey: .referenceScope)
        try container.encode(referenceEvidence, forKey: .referenceEvidence)
        try container.encode(referenceExplicit, forKey: .referenceExplicit)
        try container.encode(referenceConfidence, forKey: .referenceConfidence)
        try container.encode(constraints, forKey: .constraints)
        try container.encode(boundaries, forKey: .boundaries)
        try container.encode(risks, forKey: .risks)
        try container.encode(successCriteria, forKey: .successCriteria)
        try container.encode(openQuestions, forKey: .openQuestions)
    }

    /// 结构化的“只回复”目标:下游不能为它补文件、开预览或跑交付验收。
    var isReplyOnlyOutput: Bool {
        outputMode == .chatReply || (outputMode == .unspecified && kind == .question)
    }

    /// 结构化可视交互目标:只有这类目标才允许宿主兜底打开预览/进入演示。
    var allowsVisibleInteractionOutput: Bool {
        outputMode == .visibleInteraction || (outputMode == .unspecified && kind == .interaction)
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
        if outputMode != .unspecified { lines.append("输出模式:\(outputMode.rawValue)") }
        if referenceScope != .unknown { lines.append("引用范围:\(referenceScope.rawValue);显式:\(referenceExplicit ? "true" : "false")") }
        if referenceConfidence != .unknown { lines.append("引用置信度:\(referenceConfidence.rawValue)") }
        if !referenceEvidence.isEmpty { lines.append("引用证据:" + referenceEvidence.joined(separator: ";")) }
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
    - output_mode: 四选一 —— "chat_reply"(最终只需要聊天回复)、"artifact"(需要落文件/产物)、"visible_interaction"(需要打开/演示/讲解/播报等可感知交互)、"external_action"(需要改变外部系统/设备/网络/账号状态)
    - reference_scope: 七选一 —— "current_input"(当前输入自足)、"default_anchor"(省略/续接/指代时承接默认回合)、"candidate_background"(当前输入明确指向旧背景候选)、"visible_context"(当前输入明确指向当前可见材料/屏幕/预览)、"task_thread"(当前输入明确指向某个任务线程)、"memory"(当前输入明确要求回溯长期记忆)、"unknown"
    - reference_explicit: boolean。只有当前输入明确说出了要跳转的对象/材料/任务/记忆时才为 true;裸省略、裸续接、泛指一律 false。
    - reference_confidence: 四选一 —— "high"(上下文对象有明确原文证据且实体被保留)、"medium"(对象大致可推断但证据不完整)、"low"(看起来在指代但找不到可靠对象)、"unknown"
    - reference_evidence: 数组。放支撑 reference_scope 的短原文证据;如果选择非 default_anchor 的候选,必须引用【当前用户输入】、default_anchor、conversation_context、retrieved_history_context 或历史检索工具结果里的支撑对象。
    - constraints: 必须满足的条件数组(格式/时限/指定工具/环境约束),无则 []
    - boundaries: 明确不该做、越界即停的数组,无则 []
    - risks: 涉及隐私/资金/账号/不可逆/对外发布/物理动作等风险点数组,无则 []
    - success_criteria: 怎样算真正达成(验收依据)数组,无则 []
    - open_questions: 信息不足、需要先问用户澄清的数组,无则 []

    分类边界:
    - 如果用户消息是 LingShu active turn 上下文 JSON:只把 current_user_input 视为新的用户请求;conversation_context 是完整引用池,default_anchor 只是最近完成回合的快速锚点,不是唯一可选目标。
    - 对上下文 JSON:必须先通读 conversation_context 再选择被引用的轮次/对象。当前输入可能承接很多轮之前的某个对象/报告/文件/股票/任务,不要机械接最近一轮。只有确实没有更强语义指向时,才把 default_anchor 当作目标。
    - 如果选择的上下文里有具体实体(股票/基金/标的/文件名/路径/人名/项目名/id/编号等),objective 和 success_criteria 必须逐项保留这些实体或明确集合名,不得泛化成"之前的分析/这个文件/相关内容"。
    - 如果 reference_scope 选择 candidate_background/visible_context/task_thread/memory,reference_explicit 必须为 true,reference_evidence 必须引用 current_user_input、default_anchor、conversation_context、retrieved_history_context 或历史检索工具结果中的支撑原文。
    - 只有当你能指出被引用对象的原文证据、并在 objective / success_criteria 中保留关键实体时,reference_confidence 才能是 "high"。如果只是写成"之前的分析/那份报告/相关内容"而没有实体或证据,reference_confidence 必须是 "medium" 或 "low"。
    - question = 用户只要你给出一段信息性回答/解释/建议/比较/提醒/一句话说明,最终交付就是聊天回复本身;即使用户说"给我/告诉我/说明一下/解释一下/提醒一下/用一句话",只要不要求落文件、不要求真实操作、不要求打开/控制/发送/同步,就归 question,success_criteria 通常为 []。
    - task = 用户要求产生持久交付物或改变外部状态,例如写文件/生成 PPT 或 PDF/保存结果/修改代码/运行验证/发送同步/控制设备/操作电脑/联网采集并落档。
    - interaction = 用户要求你陪同进行一个实时过程,例如演示、讲解、答疑、带人看材料、连续播报;它不是静态文件交付,但需要持续互动。
    - 如果用户明确说"只回复/只回答/不要创建文件/不要打开预览/不要进入交付流程/不要启动任务",output_mode 必须是 "chat_reply"。即使 kind 因为“检查/验收”被判成 task,下游也只能按聊天回复收口。
    - 如果用户要"生成/保存/修改/产出文件",output_mode 是 "artifact";如果要"打开/演示/讲解/播报/答疑",output_mode 是 "visible_interaction";如果要"同步/发送/控制设备/改外部系统",output_mode 是 "external_action"。
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
        let outputMode = parseOutputMode(obj["output_mode"] ?? obj["outputMode"])
        let referenceScope = parseReferenceScope(obj["reference_scope"] ?? obj["referenceScope"])
        return LingShuGoalSpec(
            objective: objective, kind: kind,
            constraints: arr("constraints"), boundaries: arr("boundaries"), risks: arr("risks"),
            successCriteria: arr("success_criteria"), openQuestions: arr("open_questions"),
            outputMode: outputMode,
            referenceScope: referenceScope,
            referenceEvidence: arr("reference_evidence").isEmpty ? arr("referenceEvidence") : arr("reference_evidence"),
            referenceExplicit: (obj["reference_explicit"] as? Bool) ?? (obj["referenceExplicit"] as? Bool) ?? false,
            referenceConfidence: parseReferenceConfidence(obj["reference_confidence"] ?? obj["referenceConfidence"])
        )
    }

    /// 新任务真正开始前的最小结构契约。解析成 JSON 不等于 GoalSpec 已经可执行;
    /// 缺少类型、输出形态或验收标准时应重新生成,不能让下游自行猜测。
    static func executionReadinessIssue(_ spec: LingShuGoalSpec) -> String? {
        if spec.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "objective 为空"
        }
        if spec.kind == .unknown { return "kind 未明确" }
        if spec.outputMode == .unspecified { return "output_mode 未明确" }
        if spec.referenceScope == .unknown { return "reference_scope 未明确" }
        if spec.referenceConfidence == .unknown { return "reference_confidence 未明确" }
        if (spec.kind == .task || spec.kind == .interaction), spec.successCriteria.isEmpty {
            return "task/interaction 缺少 success_criteria"
        }
        return nil
    }

    static func parseOutputMode(_ raw: Any?) -> LingShuOutputMode {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return .unspecified
        }
        let normalized = value.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "reply", "chat", "answer", "chat_reply", "text_reply":
            return .chatReply
        case "artifact", "file", "deliverable":
            return .artifact
        case "visible", "interaction", "visible_interaction", "presentation", "demo":
            return .visibleInteraction
        case "external", "external_action", "action", "device_action":
            return .externalAction
        default:
            return LingShuOutputMode(rawValue: normalized) ?? .unspecified
        }
    }

    static func parseReferenceScope(_ raw: Any?) -> LingShuGoalReferenceScope {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return .unknown
        }
        let normalized = value.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "current", "current_input", "self_contained":
            return .currentInput
        case "default", "default_anchor", "recent_exchange", "latest_exchange":
            return .defaultAnchor
        case "candidate", "candidate_background", "background":
            return .candidateBackground
        case "visible", "visible_context", "preview", "screen":
            return .visibleContext
        case "thread", "task_thread", "task":
            return .taskThread
        case "memory", "long_memory":
            return .memory
        default:
            return LingShuGoalReferenceScope(rawValue: normalized) ?? .unknown
        }
    }

    static func parseReferenceConfidence(_ raw: Any?) -> LingShuGoalReferenceConfidence {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return .unknown
        }
        let normalized = value.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "high", "strong", "confident":
            return .high
        case "medium", "mid", "moderate", "partial":
            return .medium
        case "low", "weak", "uncertain":
            return .low
        default:
            return LingShuGoalReferenceConfidence(rawValue: normalized) ?? .unknown
        }
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
