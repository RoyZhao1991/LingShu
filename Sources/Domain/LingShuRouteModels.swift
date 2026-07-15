import Foundation

// 灵枢**模型网关**的路由/选择/载荷类型——与具体大脑(DeepSeek/Claude/GLM/…)和传输方式无关。
// 历史上这些类型曾叫 Codex*(灵枢早期基于 Codex 搭建),现已正名为中性的 LingShu* 路由类型;
// 它们是大脑分诊判断、选择卡片、任务分派载荷的通用结构,被任务运行时 / 对话 / 记忆 / 验收门统一使用。

/// 结构化选项：模型需要用户在有限选择中做决定时返回，界面渲染成选择卡片。
/// action 为宿主侧结构化动作（如 "resume:task-123" / "new-task"）：有 action 的选项
/// 点选后执行动作而不是把 label 当新输入提交；模型生成的选项不填 action。
struct LingShuRouteChoiceOption: Codable, Equatable, Sendable {
    var label: String
    var detail: String?
    var action: String?

    init(label: String, detail: String? = nil, action: String? = nil) {
        self.label = label
        self.detail = detail
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        detail = try? container.decode(String.self, forKey: .detail)
        action = try? container.decode(String.self, forKey: .action)
    }
}

struct LingShuRouteChoicePrompt: Codable, Equatable, Sendable {
    var question: String
    var options: [LingShuRouteChoiceOption]

    /// 过滤空标签并统一脱敏，至少要有 2 个有效选项才算合法选择卡片。
    var sanitized: LingShuRouteChoicePrompt? {
        let safeQuestion = LingShuAgentFailureDiagnosis
            .sanitizedEvidence(question, maxLength: 800)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = options.compactMap { option -> LingShuRouteChoiceOption? in
            let label = LingShuAgentFailureDiagnosis
                .sanitizedEvidence(option.label, maxLength: 120)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            let detail = option.detail.map {
                LingShuAgentFailureDiagnosis
                    .sanitizedEvidence($0, maxLength: 260)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return .init(label: label, detail: detail, action: option.action)
        }
        guard valid.count >= 2 else { return nil }
        return LingShuRouteChoicePrompt(question: safeQuestion, options: valid)
    }
}

/// 大脑分诊判断要分派给某个能力节点时的任务描述(目标/模式/节奏/理由)。
struct LingShuRouteAgentTask: Codable {
    var agent: String
    var task: String
    var mode: String?
    var cadence: String?
    var rationale: String?

    enum CodingKeys: String, CodingKey {
        case agent
        case task
        case mode
        case cadence
        case rationale
    }

    init(agent: String, task: String, mode: String? = nil, cadence: String? = nil, rationale: String? = nil) {
        self.agent = agent
        self.task = task
        self.mode = mode
        self.cadence = cadence
        self.rationale = rationale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = (try? container.decode(String.self, forKey: .agent)) ?? ""
        task = (try? container.decode(String.self, forKey: .task)) ?? ""
        mode = try? container.decode(String.self, forKey: .mode)
        cadence = try? container.decode(String.self, forKey: .cadence)
        rationale = try? container.decode(String.self, forKey: .rationale)
    }
}

/// 大脑一轮分诊的结构化输出:是否需要分派、当前口播、执行诉求、直接回答、最终回复、选择卡片。
struct LingShuRoutePayload: Codable {
    var needsAgents: Bool
    var agents: [LingShuRouteAgentTask]
    var currentReply: String?
    var executionRequest: String?
    var directAnswer: String?
    var finalAnswer: String?
    var summary: String?
    var choices: LingShuRouteChoicePrompt?

    enum CodingKeys: String, CodingKey {
        case needsAgents
        case agents
        case currentReply
        case executionRequest
        case directAnswer
        case finalAnswer
        case summary
        case choices
    }

    init(
        needsAgents: Bool,
        agents: [LingShuRouteAgentTask],
        currentReply: String? = nil,
        executionRequest: String? = nil,
        directAnswer: String? = nil,
        finalAnswer: String? = nil,
        summary: String? = nil,
        choices: LingShuRouteChoicePrompt? = nil
    ) {
        self.needsAgents = needsAgents
        self.agents = agents
        self.currentReply = currentReply
        self.executionRequest = executionRequest
        self.directAnswer = directAnswer
        self.finalAnswer = finalAnswer
        self.summary = summary
        self.choices = choices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        needsAgents = (try? container.decode(Bool.self, forKey: .needsAgents)) ?? false
        agents = (try? container.decode([LingShuRouteAgentTask].self, forKey: .agents)) ?? []
        currentReply = try? container.decode(String.self, forKey: .currentReply)
        executionRequest = try? container.decode(String.self, forKey: .executionRequest)
        directAnswer = try? container.decode(String.self, forKey: .directAnswer)
        finalAnswer = try? container.decode(String.self, forKey: .finalAnswer)
        summary = try? container.decode(String.self, forKey: .summary)
        choices = (try? container.decode(LingShuRouteChoicePrompt.self, forKey: .choices))?.sanitized
    }

    var currentUserReply: String {
        for candidate in [currentReply, finalAnswer, directAnswer, summary] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return userFacingAnswer
    }

    var userFacingAnswer: String {
        for candidate in [finalAnswer, directAnswer, summary] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }

        if needsAgents {
            let names = agents.map(\.agent).filter { !$0.isEmpty }.joined(separator: "、")
            return names.isEmpty ? "我判断这条消息需要能力节点参与，已进入分派流程。" : "我判断这条消息需要 \(names) 参与，已完成任务分派。"
        }

        return "收到。这一轮我可以直接处理。"
    }
}

/// 任务执行的权限模式(沙箱/完整)——自主运行权限门、权限策略、设置面板共用,与具体执行器无关。
enum LingShuExecutionPermissionMode: String, CaseIterable, Identifiable {
    case sandbox = "沙箱权限"
    case fullAccess = "完整权限"

    var id: String { rawValue }

    var englishName: String {
        switch self {
        case .sandbox: "Sandbox"
        case .fullAccess: "Full access"
        }
    }

    var detail: String {
        switch self {
        case .sandbox:
            "仅允许在目标项目目录内读写，适合日常开发。"
        case .fullAccess:
            "允许访问更完整的本机文件系统，适合你明确授权的系统级操作。"
        }
    }
}
