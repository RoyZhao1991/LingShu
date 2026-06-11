import Foundation

struct LingShuExecutionContext: Equatable {
    var isDevelopmentQueueRequest: Bool
    var isProjectExecutionRequest: Bool
    var isKnowledgeOnlyQuestion: Bool
    var isCapabilityCollaborationRequest: Bool
}

struct LingShuDialogueAcknowledgement {
    /// 思考占位不再用机械的第一人称独白；返回空串，界面只显示一个安静的思考指示，
    /// 等真实回复一到就替换。避免每轮都甩同一句“我先判断这件事…”的人机感。
    func intake(for prompt: String) -> String {
        ""
    }

    func routeReply(
        for route: CodexRoutePayload,
        fallback: String,
        willExecute: Bool
    ) -> String {
        guard route.needsAgents else {
            let direct = route.userFacingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            return direct.isEmpty ? fallback : direct
        }

        guard willExecute else {
            let planned = route.userFacingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            return planned.isEmpty ? fallback : planned
        }

        let agentNames = route.agents
            .map(\.agent)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "、")
        let assignee = agentNames.isEmpty ? "相关能力节点" : agentNames
        return "收到。这件事需要能力节点协作，我已分派给 \(assignee)。后台正在执行，我会把结果回传给你。"
    }
}

struct LingShuExecutionCoordinator {
    func shouldStartExecutionThread(
        userPrompt: String,
        route: CodexRoutePayload,
        context: LingShuExecutionContext
    ) -> Bool {
        guard route.needsAgents else { return false }
        if context.isDevelopmentQueueRequest || context.isProjectExecutionRequest {
            return true
        }
        if context.isKnowledgeOnlyQuestion {
            return false
        }

        let normalized = normalize(userPrompt)
        let executionSignals = [
            "帮我做", "做一个", "做成", "推进", "落地", "实现", "开发",
            "生成", "产出", "修复", "测试", "验收", "迭代", "优化",
            "需求分析", "需求文档", "业务说明书", "技术方案", "ppt",
            "幻灯片", "演示文稿", "汇报材料", "设计稿", "视觉方案", "版式"
        ]

        return context.isCapabilityCollaborationRequest
            && executionSignals.contains { normalized.contains($0) }
    }

    func executionPrompt(
        userPrompt: String,
        route: CodexRoutePayload,
        memoryHint: String,
        isProjectExecutionRequest: Bool
    ) -> String {
        let plan = route.agents.enumerated().map { index, task in
            let mode = task.mode?.isEmpty == false ? task.mode! : "执行"
            let cadence = task.cadence?.isEmpty == false ? task.cadence! : "本轮"
            let rationale = task.rationale?.isEmpty == false ? task.rationale! : "灵枢判断需要参与"
            return "\(index + 1). \(task.agent)：\(task.task)；模式：\(mode)；节奏：\(cadence)；依据：\(rationale)"
        }.joined(separator: "\n")
        let executionScope = isProjectExecutionRequest
            ? "本轮是项目执行任务。可以检查当前项目必要文件、做必要修改，并运行合理验证。"
            : "本轮是轻量开发产出任务，但用户没有授权修改当前项目。不要读取、扫描、修改工作区，不要运行构建或测试；请直接产出可运行结果、依赖说明和使用方式。"
        let designDeliveryScope = route.agents.contains { LingShuCapabilityRole.normalize($0.agent) == .design }
            ? "\n        本轮包含设计交付：先明确受众、场景、叙事结构、视觉风格、页级结构、素材/图表需求；如果用户要求 PPT 文件或演示文稿，必须给出可保存的文件交付路径、生成方式和验证方式。"
            : ""

        return """
        这是灵枢完成首轮思考、并经过通用治理链路后的任务运行时阶段。你是被调度的执行器，不是灵枢本人；请按闭环流程推进任务，并把执行报告回传给灵枢。
        灵枢是通用中枢，负责承令、规划、审议、调度、权限裁决、过程监控和最终验收；规划节点负责形成方案，审议节点负责风险和权限审核，调度节点负责落地分派；你负责在授权范围内完成执行、检查、修正或产出。

        原始用户指令：
        \(userPrompt)

        灵枢已经分派的专家 agent：
        \(plan)

        执行范围：
        \(executionScope)
        \(designDeliveryScope)

        执行记忆：
        \(memoryHint)

        记忆恢复规则：
        - 如果执行记忆命中历史项目、历史线程或冷备摘要，先用它恢复目标、约束、已完成事项和未完成风险。
        - 记忆只作为上下文，不代表本轮已经完成；实际动作仍必须遵守当前执行范围和权限。
        - 如果记忆和本轮用户指令冲突，以本轮用户指令和当前权限为准，并在回传报告里说明冲突。

        标准工程闭环：
        1. Intake：确认任务目标和交付口径。
        2. Context：只读取必要上下文，不扫无关文件。
        3. Plan：形成最小可执行计划。
        4. Permission：遵守当前权限边界，高风险动作先停止并请求确认。
        5. Execute：必要时读文件、改文件、运行命令、观察输出。
        6. Monitor：持续根据输出、diff、测试结果调整。
        7. Check：运行合理验证；无法验证要说明原因。
        8. Review：汇总改动、证据、风险和下一步。
        9. Deliver：把结果回传给灵枢，由灵枢对用户负责。

        执行要求：
        - 只有当原始用户指令明确要求你操作当前项目、修改文件、运行构建或测试时，才检查项目文件并做真实改动。
        - 如果任务只是咨询、研究、规划或代码示例，请直接产出可交付结论，不要假装做了文件修改，也不要长时间扫描整个工作区。
        - 每轮交付前做收束判断：显性需求是否满足，潜在下一步是否明显，当前满足度是否足够。如果满足度高就干净收束；如果只完成了第一层交付，或后续很可能需要落地、验证、细化、保存、运行、审查、生成产物，只提出一个自然的继续推进问题。不要针对某个关键词使用固定追问模板。
        - 只有用户确认继续推进后，下一轮才进入本机文件写入、命令运行或系统控制。
        - 不要用“规划 agent：”“执行 agent：”等多角色对话格式。最终只以“灵枢”的口吻给用户简报。
        - 不要主动提到底层模型、Codex、CLI、Auth 或 JSON 等实现细节。
        - 高风险操作、删除文件、提交代码、发送外部请求或真实部署前必须停止并说明需要用户确认。
        - 最终回传给灵枢的报告必须包含：完成了什么、是否读写文件、是否运行验证、风险、是否需要用户 Review、需求满足度判断和自然下一步。
        """
    }

    func postProcessExecutionReply(
        _ reply: String,
        userPrompt: String,
        route: CodexRoutePayload,
        context: LingShuExecutionContext
    ) -> String {
        var finalReply = Self.sanitizeServerArtifactReferences(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldAskForContinuation(after: finalReply, prompt: userPrompt, route: route, context: context) else {
            return finalReply
        }

        let continuation = continuationQuestion(for: userPrompt, context: context)
        finalReply = finalReply.isEmpty ? continuation : "\(finalReply)\n\n\(continuation)"
        return finalReply
    }

    /// 清除模型虚构/引用的“网关后端文件”：服务端路径、minio 预签名下载链接、文件下载段。
    /// 灵枢的真实交付物是本机生成的产出物（见产出物清单），不应把用户拿不到、且违反零留存的
    /// 云端链接当成交付。
    static func sanitizeServerArtifactReferences(_ text: String) -> String {
        let serverTokens = [
            "minio.", "/v1/files/download", "x-amz-", "hermes-export",
            "/opt/hermes", "/opt/preannotation", "ai-temp-film", "presigned"
        ]
        var keptLines: [String] = []
        var skippingDownloadSection = false

        for rawLine in text.components(separatedBy: "\n") {
            let lower = rawLine.lowercased()
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // 跳过“文件下载/下载链接”小节标题及其后续直到空行或下一个标题。
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("**") {
                if trimmed.contains("文件下载") || trimmed.contains("下载链接") || lower.contains("download") {
                    skippingDownloadSection = true
                    continue
                }
                skippingDownloadSection = false
            }
            if skippingDownloadSection {
                if trimmed.isEmpty { skippingDownloadSection = false }
                continue
            }

            if serverTokens.contains(where: { lower.contains($0) }) {
                continue
            }
            keptLines.append(rawLine)
        }

        return keptLines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldAskForContinuation(
        after reply: String,
        prompt: String,
        route: CodexRoutePayload,
        context: LingShuExecutionContext
    ) -> Bool {
        let normalizedReply = normalize(reply)
        let normalizedPrompt = normalize(prompt)

        if normalizedReply.isEmpty { return true }

        let alreadyClosingOrAsking = [
            "需要我", "是否需要", "要不要", "要我", "是否继续", "继续推进",
            "下一步", "还有什么", "可以继续", "请确认", "等待你确认"
        ].contains { normalizedReply.contains($0) } || reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("？")

        if alreadyClosingOrAsking { return false }

        let purelyConversational = [
            "你是谁", "你是什么", "你叫什么", "你好", "在吗"
        ].contains { normalizedPrompt.contains($0) }

        if purelyConversational { return false }

        let hasNaturalFollowUpPotential = route.needsAgents
            || context.isCapabilityCollaborationRequest
            || context.isDevelopmentQueueRequest
            || [
                "写", "做", "实现", "生成", "优化", "修复", "设计", "方案", "规划",
                "分析", "文档", "测试", "运行", "落地", "迭代", "检查",
                "ppt", "幻灯片", "演示", "汇报", "版式", "视觉"
            ].contains { normalizedPrompt.contains($0) }

        guard hasNaturalFollowUpPotential else { return false }

        let stronglyComplete = [
            "验证通过", "测试通过", "已经完成", "已完成", "无需下一步", "可以直接交付",
            "没有风险", "不需要继续", "本轮完成"
        ].contains { normalizedReply.contains($0) }

        return !stronglyComplete
    }

    private func continuationQuestion(for prompt: String, context: LingShuExecutionContext) -> String {
        let normalizedPrompt = normalize(prompt)

        if context.isProjectExecutionRequest || normalizedPrompt.contains("修复") || normalizedPrompt.contains("报错") {
            return "我判断这轮还没有形成完整的验证闭环。需要我继续推进到检查、修正和验收么？"
        }

        if context.isDevelopmentQueueRequest {
            return "我判断当前已经覆盖第一层交付，但还没有进入落地和验证。需要我继续推进当前工作内容么？"
        }

        if normalizedPrompt.contains("方案") || normalizedPrompt.contains("规划") || normalizedPrompt.contains("设计") {
            return "我判断当前方案还可以继续细化成可执行步骤。需要我继续往下推进么？"
        }

        return "我判断这里还有自然的下一步可以推进。需要我继续处理当前工作内容么？"
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "；", with: "")
            .replacingOccurrences(of: ";", with: "")
    }
}
