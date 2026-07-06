import Foundation

/// 通用中枢 P1·目标认知**接线**(见 `Docs/通用AI中枢推进方案.md`)。
/// **P1 完全落地**:入口(`submitTextInput` 分诊之前)派生 `LingShuGoalSpec` 并存 `goalSpecsByRecord`,
/// 由 ① `driveAgentDelivery` 注入执行引导(循环消费)② `verifyAgentDeliverable` 引用成功标准(验收消费)
/// ③ 任务记录落痕(记忆消费)。开关 `lingshu.goalSpec`(DEBUG 默认开)。
@MainActor
extension LingShuState {

    /// 目标认知开关:**默认开(发布态亦然=完整可用)**;配置入口 `setGoalSpecEnabled` / MCP `lingshu_set_goalspec` 可关。
    /// 关 → 零行为/零成本变更(不发那次解析模型调用、不注入引导/成功标准/不沉淀经验)。状态见 `lingshu_status.goalSpecEnabled`。
    var goalSpecEnabled: Bool {
        UserDefaults.standard.object(forKey: "lingshu.goalSpec") as? Bool ?? true
    }

    /// 配置入口:开/关目标认知(持久化 UserDefaults,跨重启)。供 MCP `lingshu_set_goalspec` / 设置 UI 调用。
    func setGoalSpecEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "lingshu.goalSpec")
        appendTrace(kind: .system, actor: "目标认知", title: on ? "已开启" : "已关闭",
                    detail: on ? "每个新顶层目标先结构化理解(GoalSpec)→ 注入执行引导/验收成功标准/沉淀经验。"
                               : "已关闭:零成本零行为变更。")
    }

    /// 从一条用户请求派生 GoalSpec(模型 1-shot、无工具),落 trace。返回解析结果(失败 nil)。
    /// 调用方拿到后存 `goalSpecsByRecord[记录]` → 供执行引导/验收成功标准/记忆消费。
    @discardableResult
    func deriveGoalSpec(for request: String, taskRecordID: String?, activeTurnContext: Bool = false) async -> LingShuGoalSpec? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let activeTurnAnchor = activeTurnContext ? activeTurnGoalSpecLatestCompletedExchange(excludingCurrentRawPrompt: trimmed) : []
        let activeTurnAnchorIsInteractive: Bool = {
            guard activeTurnContext,
                  let anchor = activeTurnGoalSpecLatestCompletedAssistant(excludingCurrentRawPrompt: trimmed),
                  let recordID = anchor.taskRecordID
            else { return false }
            return turnDidProvideInteractiveOutput(recordID)
        }()
        let modelRequest = activeTurnContext ? activeTurnGoalSpecRequest(for: trimmed) : trimmed
        let adapter = controlPlaneModelAdapter(.goalSpec, taskRecordID: taskRecordID)
        let session = LingShuAgentSession(
            id: "goalspec-\(UUID().uuidString.prefix(6))",
            system: LingShuGoalSpecParser.systemPrompt,
            tools: [], model: adapter, maxTurns: 1
        )
        guard case .completed(let text) = await session.send(modelRequest) else { return nil }
        guard let spec = LingShuGoalSpecParser.parse(LingShuReasoningText.stripThinkTags(text)) else {
            appendTrace(kind: .system, actor: "目标认知", title: "GoalSpec 解析失败",
                        detail: "模型未产出可解析的目标规格(本回合按无目标规格执行,不影响)。")
            return nil
        }
        let normalized = activeTurnContext
            ? Self.repairActiveTurnGoalSpecReference(
                spec,
                currentInput: trimmed,
                defaultAnchorLines: activeTurnAnchor,
                defaultAnchorIsInteractive: activeTurnAnchorIsInteractive
            )
            : spec
        if normalized != spec {
            appendTrace(kind: .system, actor: "目标认知", title: "GoalSpec 引用范围修正",
                        detail: "模型给出的引用范围缺少显式证据,已回落到默认承接回合。raw=\(spec.summary)\nnormalized=\(normalized.summary)")
        }
        appendTrace(kind: .system, actor: "目标认知", title: "GoalSpec", detail: normalized.summary)
        return normalized
    }

    /// 顶层 active turn 的目标认知信封:把**当前输入**和**最近对话前景**一起交给目标解析模型。
    /// 这不是关键词规则;它解决的是省略/指代/续接类输入在第④站丢上下文的问题。
    /// 子任务/后台任务仍用自己的 objective 派生,避免前台聊天污染隔离线程。
    func activeTurnGoalSpecRequest(for request: String) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return request }
        let foreground = activeTurnGoalSpecForegroundLines(excludingCurrentRawPrompt: trimmed)
        let anchor = activeTurnGoalSpecLatestCompletedExchange(excludingCurrentRawPrompt: trimmed)
        guard !foreground.isEmpty else { return trimmed }
        let payload: [String: Any] = [
            "type": "lingshu_active_turn_goal_context",
            "contract": [
                "current_user_input_is_the_only_new_request": true,
                "default_anchor_is_primary_for_ellipsis": true,
                "candidate_background_is_optional_only": true,
                "must_return_reference_scope_fields": true
            ],
            "current_user_input": trimmed,
            "default_anchor": anchor,
            "candidate_background": foreground,
            "selection_rules": [
                "If current_user_input does not explicitly name another object/thread/material/memory, set reference_scope=default_anchor and reference_explicit=false.",
                "If reference_scope is candidate_background/visible_context/task_thread/memory, reference_explicit must be true and reference_evidence must quote the explicit object from current_user_input or default_anchor.",
                "Do not let older candidate_background override default_anchor."
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return """
        current_user_input=\(trimmed)
        default_anchor=\(anchor.joined(separator: "\n"))
        candidate_background=\(foreground.joined(separator: "\n"))
        """
    }

    /// 第④站引用范围修复闸:只看模型**结构字段**,不看“继续/PPT/介绍”等关键词。
    /// 如果模型想从默认承接跳到旧候选,但没有声明显式引用证据,就回落到默认承接回合。
    nonisolated static func repairActiveTurnGoalSpecReference(
        _ spec: LingShuGoalSpec,
        currentInput: String,
        defaultAnchorLines: [String],
        defaultAnchorIsInteractive: Bool = false
    ) -> LingShuGoalSpec {
        var repaired = spec
        let evidence = spec.referenceEvidence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let supportCorpus = ([currentInput] + defaultAnchorLines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuotedSupport = evidence.contains { supportCorpus.contains($0) }

        if spec.referenceScope.escapesDefaultAnchor,
           (!spec.referenceExplicit || evidence.isEmpty || !hasQuotedSupport) {
            repaired.objective = "基于默认承接回合继续回应当前用户输入"
            repaired.kind = .question
            repaired.outputMode = .chatReply
            repaired.referenceScope = .defaultAnchor
            repaired.referenceExplicit = false
            repaired.referenceEvidence = defaultAnchorLines.isEmpty ? [] : Array(defaultAnchorLines.suffix(2))
            repaired.successCriteria = []
            if !repaired.constraints.contains("优先承接默认承接回合") {
                repaired.constraints.append("优先承接默认承接回合")
            }
            if !repaired.boundaries.contains("不得跳到无显式证据的旧候选上下文") {
                repaired.boundaries.append("不得跳到无显式证据的旧候选上下文")
            }
        }

        if repaired.referenceScope == .defaultAnchor,
           !repaired.referenceExplicit,
           repaired.allowsVisibleInteractionOutput,
           !defaultAnchorIsInteractive {
            repaired.kind = .question
            repaired.outputMode = .chatReply
            repaired.successCriteria = []
            if !repaired.boundaries.contains("默认承接回合不是可视交互产出时不得升级为可视交互") {
                repaired.boundaries.append("默认承接回合不是可视交互产出时不得升级为可视交互")
            }
        }
        return repaired
    }

    private func activeTurnGoalSpecLatestCompletedExchange(excludingCurrentRawPrompt rawPrompt: String) -> [String] {
        let visible = activeTurnGoalSpecForegroundMessages(excludingCurrentRawPrompt: rawPrompt)
        guard let assistantIndex = visible.lastIndex(where: { !$0.isUser }) else { return [] }
        var lines: [String] = []
        if let userIndex = visible[..<assistantIndex].lastIndex(where: { $0.isUser }) {
            lines.append(activeTurnGoalSpecLine(for: visible[userIndex]))
        }
        lines.append(activeTurnGoalSpecLine(for: visible[assistantIndex]))
        return lines
    }

    private func activeTurnGoalSpecLatestCompletedAssistant(excludingCurrentRawPrompt rawPrompt: String) -> ChatMessage? {
        activeTurnGoalSpecForegroundMessages(excludingCurrentRawPrompt: rawPrompt)
            .last(where: { !$0.isUser })
    }

    private func activeTurnGoalSpecForegroundLines(excludingCurrentRawPrompt rawPrompt: String, limit: Int = 8, budget: Int = 3600) -> [String] {
        var remaining = budget
        var reversed: [String] = []
        for message in activeTurnGoalSpecForegroundMessages(excludingCurrentRawPrompt: rawPrompt).reversed() {
            let line = activeTurnGoalSpecLine(for: message)
            guard line.count <= remaining else { break }
            reversed.append(line)
            remaining -= line.count
            if reversed.count >= limit { break }
        }
        return reversed.reversed()
    }

    private func activeTurnGoalSpecForegroundMessages(excludingCurrentRawPrompt rawPrompt: String) -> [ChatMessage] {
        let raw = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var skippedCurrentUserPrompt = false
        return chatMessages.reversed().compactMap { message -> ChatMessage? in
            guard !message.isLoading else { return nil }
            let text = LingShuState.compactForModelContext(message.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if !skippedCurrentUserPrompt, message.isUser, text == raw {
                skippedCurrentUserPrompt = true
                return nil
            }
            var cleaned = message
            cleaned.text = text
            return cleaned
        }.reversed()
    }

    private func activeTurnGoalSpecLine(for message: ChatMessage) -> String {
        "\(message.isUser ? "用户" : "灵枢"): \(message.text)"
    }

    /// 把派生好的 GoalSpec **绑定为记录的 typed 字段**(随记录持久化跨重启)+ 落记录时间线。
    /// 记录是单一真相:执行引导/验收/记忆都从 `goalSpec(for:)` 读它,重启后链路仍拿得到 typed 值。
    func bindGoalSpec(_ spec: LingShuGoalSpec?, to recordID: String) {
        guard let spec, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        taskExecutionRecords[idx].goalSpec = spec
        appendTaskRecordMessage(recordID, actor: "目标认知", role: "目标", kind: .core, text: spec.summary)
    }

    /// 取某任务记录的 typed GoalSpec(单一真相 = 记录字段,跨重启可用)。
    func goalSpec(for recordID: String?) -> LingShuGoalSpec? {
        guard let recordID else { return nil }
        return taskExecutionRecords.first(where: { $0.id == recordID })?.goalSpec
    }

    /// 第④站标准挂点:新的 Active Turn 先做 GoalSpec;只有真实执行/交互型目标才继续加重能力核验。
    nonisolated static func goalKindNeedsCapabilityPreflight(_ kind: LingShuGoalKind?) -> Bool {
        kind == .task || kind == .interaction
    }

    /// 第④站 trace 统一格式。后续查问题时不要靠自然语言猜,直接看 flow/stage/route/kind/count。
    nonisolated static func activeTurnPreflightTrace(
        stage: String,
        route: String,
        recordID: String?,
        goalKind: LingShuGoalKind?,
        capabilityPreflight: Bool,
        requirementsCount: Int,
        hasGap: Bool,
        reason: String
    ) -> String {
        [
            "flow=active_turn",
            "stage=\(stage)",
            "route=\(route)",
            "record=\(recordID ?? "-")",
            "goalKind=\(goalKind?.rawValue ?? "none")",
            "capabilityPreflight=\(capabilityPreflight ? "on" : "off")",
            "requirements=\(requirementsCount)",
            "gap=\(hasGap ? "present" : "none")",
            "reason=\(reason)"
        ].joined(separator: "; ")
    }

    /// P1·**记忆消费(结构化经验沉淀)**:目标到终态时,把「目标→成功标准→结果→产出/失败原因」蒸成一条
    /// **可检索经验**入知识图谱(陈述句、过去式,经纪律闸 + 园丁去重)。下次同类目标 `recall_memory`/seed 即接续历史经验。
    /// 只沉淀终态(完成/直答/未达标),blocked/暂停不沉淀(未定论)。无 GoalSpec(开关关或非新目标)则空跑。
    func rememberGoalExperienceIfNeeded(recordID: String, status: LingShuTaskExecutionStatus) {
        guard let rec = taskExecutionRecords.first(where: { $0.id == recordID }), let spec = rec.goalSpec else { return }
        guard let outcome = Self.experienceOutcome(for: status) else { return }   // 排队/执行/就绪/待用户/补齐中/暂停/阻断:非终态或无定论,不沉淀
        var body = "经验:目标「\(spec.objective)」(\(spec.kind.rawValue))结果=\(outcome)。"
        if !spec.successCriteria.isEmpty { body += "成功标准:\(spec.successCriteria.joined(separator: ";"))。" }
        let artifacts = rec.artifacts.map(\.location).prefix(3)
        if !artifacts.isEmpty { body += "产出:\(artifacts.joined(separator: "、"))。" }
        // P2 真闭环:沉淀能力缺口与补齐过程(缺了什么、试了哪些路径、成败、成功能力如何复用)。
        if let attempts = rec.acquisitionAttempts, !attempts.isEmpty {
            let parts = attempts.map { "「\($0.capability)」经\($0.path)→\($0.outcome.rawValue)" }
            body += "能力补齐:\(parts.joined(separator: ";"))。"
            if attempts.contains(where: { $0.outcome == .acquiredVerified }) {
                body += "(已补齐的能力已入图谱,下次同类目标可直接复用。)"
            }
        }
        if outcome == "未达标", !rec.summary.isEmpty { body += "未达标小结:\(rec.summary.prefix(120))。" }
        _ = knowledgeGraph.remember(.init(kind: .fact, title: String(spec.objective.prefix(60)),
                                          body: body, source: .inference, confidence: 0.5))
        appendTrace(kind: .result, actor: "经验沉淀", title: "目标经验入图谱", detail: String(body.prefix(80)))
        // P4 经验闭环:同时存一条**结构化、可主动召回复用**的经验(下次同类目标执行前自动注入引导)。
        let lesson = distilledGoalLesson(outcome: outcome, spec: spec, record: rec)
        recordGoalExperience(.init(objective: spec.objective, kind: spec.kind.rawValue, outcome: outcome,
                                   lesson: lesson,
                                   sourceRecordID: recordID))
        if Self.shouldPersistExperienceRule(outcome: outcome) {
            _ = memoryService.rememberExperienceRule(domain: spec.kind.rawValue, rule: lesson, source: recordID)
        }
        // P6 自动触发:非成功终态落库即挖一次反复弱点(纯,无模型调用),失败成簇即自动提待批改进提案(去重、不自动采纳)。
        autoMineSelfImprovementsOnFailure(outcome: outcome)
    }
}
