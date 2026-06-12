import Foundation

// Codex 通道的数据类型（命令结果、探活报告、路由载荷、权限模式）。
// 从 CodexBridge.swift 拆出，保持桥接逻辑文件在 800 行硬上限以内。

struct CodexCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct CodexHealthProbeReport: Equatable {
    var reply: String
    var rawLog: String
}

struct CodexHealthProbeFailure: Error, Equatable {
    var message: String
    var rawLog: String

    var diagnosticSummary: String {
        CodexDiagnosticLogFilter.diagnosticSummary(from: rawLog)
    }
}

enum CodexHealthProbeResult: Equatable {
    case success(CodexHealthProbeReport)
    case failure(CodexHealthProbeFailure)
}

enum CodexReplyResult {
    case success(String)
    case failure(String)
}

struct CodexAgentTask: Codable {
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

/// 结构化选项：模型需要用户在有限选择中做决定时返回，界面渲染成选择卡片。
struct CodexRouteChoiceOption: Codable, Equatable, Sendable {
    var label: String
    var detail: String?

    init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        detail = try? container.decode(String.self, forKey: .detail)
    }
}

struct CodexRouteChoicePrompt: Codable, Equatable, Sendable {
    var question: String
    var options: [CodexRouteChoiceOption]

    /// 过滤掉空标签，至少要有 2 个有效选项才算合法选择卡片。
    var sanitized: CodexRouteChoicePrompt? {
        let valid = options.filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard valid.count >= 2 else { return nil }
        return CodexRouteChoicePrompt(question: question, options: valid)
    }
}

struct CodexRoutePayload: Codable {
    var needsAgents: Bool
    var agents: [CodexAgentTask]
    var currentReply: String?
    var executionRequest: String?
    var directAnswer: String?
    var finalAnswer: String?
    var summary: String?
    var choices: CodexRouteChoicePrompt?

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
        agents: [CodexAgentTask],
        currentReply: String? = nil,
        executionRequest: String? = nil,
        directAnswer: String? = nil,
        finalAnswer: String? = nil,
        summary: String? = nil,
        choices: CodexRouteChoicePrompt? = nil
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
        agents = (try? container.decode([CodexAgentTask].self, forKey: .agents)) ?? []
        currentReply = try? container.decode(String.self, forKey: .currentReply)
        executionRequest = try? container.decode(String.self, forKey: .executionRequest)
        directAnswer = try? container.decode(String.self, forKey: .directAnswer)
        finalAnswer = try? container.decode(String.self, forKey: .finalAnswer)
        summary = try? container.decode(String.self, forKey: .summary)
        choices = (try? container.decode(CodexRouteChoicePrompt.self, forKey: .choices))?.sanitized
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

enum CodexRouteResult {
    case success(CodexRoutePayload)
    case failure(String)
}

enum CodexPermissionMode: String, CaseIterable, Identifiable {
    case sandbox = "沙箱权限"
    case fullAccess = "完整权限"

    var id: String { rawValue }

    var sandboxArgument: String {
        switch self {
        case .sandbox: "workspace-write"
        case .fullAccess: "danger-full-access"
        }
    }

    var detail: String {
        switch self {
        case .sandbox:
            "仅允许 Codex 在目标项目内读写，适合日常开发。"
        case .fullAccess:
            "允许 Codex 访问更完整的本机文件系统，适合你明确授权的系统级操作。"
        }
    }
}
