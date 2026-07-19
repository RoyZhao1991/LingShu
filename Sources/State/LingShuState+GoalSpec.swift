import Foundation
/// 通用中枢 P1·目标认知**接线**(见 `Docs/通用AI中枢推进方案.md`)。
/// 入口派生 `LingShuGoalSpec`,由执行、验收与记忆链路共同消费;开关为 `lingshu.goalSpec`。
@MainActor
extension LingShuState {
    /// 目标认知开关:**默认开(发布态亦然=完整可用)**;配置入口 `setGoalSpecEnabled` / MCP `lingshu_set_goalspec` 可关。
    /// 关 → 零行为/零成本变更(不发那次解析模型调用、不注入引导/成功标准/不沉淀经验)。状态见 `lingshu_status.goalSpecEnabled`。
    var goalSpecEnabled: Bool {
        LingShuRuntimeEnvironment.preferences.object(forKey: "lingshu.goalSpec") as? Bool ?? true
    }

    /// 配置入口:开/关目标认知(持久化 UserDefaults,跨重启)。供 MCP `lingshu_set_goalspec` / 设置 UI 调用。
    func setGoalSpecEnabled(_ on: Bool) {
        LingShuRuntimeEnvironment.preferences.set(on, forKey: "lingshu.goalSpec")
        appendTrace(kind: .system, actor: "目标认知", title: on ? "已开启" : "已关闭",
                    detail: on ? "每个新顶层目标先结构化理解(GoalSpec)→ 注入执行引导/验收成功标准/沉淀经验。"
                               : "已关闭:零成本零行为变更。")
    }

    /// 从一条用户请求派生 GoalSpec。每次都携带同一份完整上下文建立新会话;
    /// 超时、模型中断或结构不完整时有界重新生成。重试耗尽返回 nil,由入口硬门阻止执行。
    /// 调用方拿到后存 `goalSpecsByRecord[记录]` → 供执行引导/验收成功标准/记忆消费。
    @discardableResult
    func deriveGoalSpec(
        for request: String,
        taskRecordID: String?,
        activeTurnContext: Bool = false,
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) async -> LingShuGoalSpec? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let activeTurnAnchor = activeTurnContext ? activeTurnGoalSpecLatestCompletedExchange(excludingCurrentRawPrompt: trimmed) : []
        let activeTurnSupportLines = activeTurnContext ? activeTurnGoalSpecReferenceSupportLines(excludingCurrentRawPrompt: trimmed) : []
        let activeTurnAnchorIsInteractive: Bool = {
            guard activeTurnContext,
                  let anchor = activeTurnGoalSpecLatestCompletedAssistant(excludingCurrentRawPrompt: trimmed),
                  let recordID = anchor.taskRecordID
            else { return false }
            return turnDidProvideInteractiveOutput(recordID)
        }()
        let modelRequest = activeTurnContext ? activeTurnGoalSpecRequest(for: trimmed) : trimmed
        guard var spec = await generateValidatedGoalSpec(
            modelRequest: modelRequest,
            taskRecordID: taskRecordID,
            allowUnresolvedReference: activeTurnContext,
            onProgress: onProgress
        ) else { return nil }
        var historyFallbackSupportLines: [String] = []
        if activeTurnContext, Self.activeTurnGoalSpecNeedsHistoryFallback(spec, currentInput: trimmed) {
            guard let fallback = await deriveGoalSpecWithHistoryFallback(
                for: trimmed,
                initialSpec: spec,
                taskRecordID: taskRecordID,
                onProgress: onProgress
            ) else {
                appendTrace(kind: .system, actor: "目标认知", title: "GoalSpec 历史归属失败·已阻止执行",
                            detail: "首轮 GoalSpec 不具备高置信引用,历史检索重试后仍无法确认对象。未使用低置信结果继续执行。")
                return nil
            }
            spec = fallback.spec
            historyFallbackSupportLines = fallback.supportLines
        }
        let normalized = activeTurnContext
            ? Self.repairActiveTurnGoalSpecReference(
                spec,
                currentInput: trimmed,
                defaultAnchorLines: activeTurnAnchor,
                candidateSupportLines: activeTurnSupportLines + historyFallbackSupportLines,
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
        guard let payload = activeTurnGoalSpecContextPayload(for: trimmed) else { return trimmed }
        return serializedGoalSpecPayload(payload, fallbackText: trimmed)
    }

    func activeTurnGoalSpecContextPayload(for trimmed: String) -> [String: Any]? {
        let foreground = activeTurnGoalSpecForegroundLines(excludingCurrentRawPrompt: trimmed)
        let conversationContext = activeTurnGoalSpecConversationContext(excludingCurrentRawPrompt: trimmed)
        let anchor = activeTurnGoalSpecLatestCompletedExchange(excludingCurrentRawPrompt: trimmed)
        let currentResources = activeTurnGoalSpecCurrentInputResources(matching: trimmed)
        guard !foreground.isEmpty || !conversationContext.isEmpty || !currentResources.isEmpty else { return nil }
        let payload: [String: Any] = [
            "type": "lingshu_active_turn_goal_context",
            "contract": [
                "current_user_input_is_the_only_new_request": true,
                "current_input_resources_are_part_of_the_new_request": true,
                "conversation_context_is_reference_pool": true,
                "default_anchor_is_fallback_not_the_only_target": true,
                "candidate_background_is_optional_only": true,
                "must_return_reference_scope_fields": true,
                "must_preserve_entities_from_selected_context": true,
                "must_return_reference_confidence": true
            ],
            "current_user_input": trimmed,
            "current_input_resources": currentResources,
            "default_anchor": anchor,
            "candidate_background": foreground,
            "conversation_context": conversationContext,
            "selection_rules": [
                "Read the full conversation_context before choosing the referenced turn; the target may be many turns earlier, not only the latest default_anchor.",
                "Treat current_input_resources as attached inputs of the current request. Preserve each attached file name and path in objective/constraints when relevant; never claim an attached resource is missing.",
                "Use default_anchor only when it is truly the best semantic target or the input is a bare continuation with no better referenced object in conversation_context.",
                "If the selected context contains concrete entities (stocks, files, people, ids, task names, paths, products), preserve those entities in objective and success_criteria instead of collapsing them into generic labels.",
                "If reference_scope is candidate_background/visible_context/task_thread/memory, reference_explicit must be true and reference_evidence must quote support from current_user_input, default_anchor, or conversation_context.",
                "Do not let noisy or failed older turns override a clearly referenced target, but do not ignore an older turn when current_user_input semantically points to it."
            ]
        ]
        return payload
    }

    func serializedGoalSpecPayload(_ payload: [String: Any], fallbackText: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return fallbackText
    }

    /// 第④站引用范围修复闸:只看模型**结构字段**,不看“继续/PPT/介绍”等关键词。
    /// 如果模型想从默认承接跳到旧候选,但没有声明显式引用证据,就回落到默认承接回合。
    nonisolated static func repairActiveTurnGoalSpecReference(
        _ spec: LingShuGoalSpec,
        currentInput: String,
        defaultAnchorLines: [String],
        candidateSupportLines: [String] = [],
        defaultAnchorIsInteractive: Bool = false
    ) -> LingShuGoalSpec {
        var repaired = spec
        let evidence = spec.referenceEvidence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let supportCorpus = ([currentInput] + defaultAnchorLines + candidateSupportLines)
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

    /// GoalSpec 的完整引用池:按时间顺序给模型一段更宽的上下文,让「更详细/复核/继续那份」
    /// 不被硬绑到最近一轮。旧的 default_anchor / candidate_background 保留做兼容和快速锚点。
    private func activeTurnGoalSpecConversationContext(
        excludingCurrentRawPrompt rawPrompt: String,
        limit: Int = 80,
        budget: Int = LingShuState.conversationContextBudget
    ) -> [[String: Any]] {
        let visible = activeTurnGoalSpecForegroundMessages(excludingCurrentRawPrompt: rawPrompt)
        guard !visible.isEmpty else { return [] }
        var remaining = budget
        var selected: [(index: Int, message: ChatMessage, text: String)] = []
        for (index, message) in visible.enumerated().reversed() {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let overhead = 160
            let cost = text.count + overhead
            if cost > remaining {
                if selected.isEmpty {
                    let room = max(200, remaining - overhead)
                    selected.append((index, message, String(text.prefix(room)) + "…（节选）"))
                }
                break
            }
            selected.append((index, message, text))
            remaining -= cost
            if selected.count >= limit { break }
        }
        let formatter = ISO8601DateFormatter()
        return selected.reversed().map { item in
            var entry: [String: Any] = [
                "turn_index": item.index + 1,
                "role": item.message.isUser ? "user" : "assistant",
                "speaker": item.message.speaker,
                "text": item.text,
                "created_at": formatter.string(from: item.message.createdAt)
            ]
            if let taskRecordID = item.message.taskRecordID {
                entry["task_record_id"] = taskRecordID
            }
            return entry
        }
    }

    private func activeTurnGoalSpecReferenceSupportLines(excludingCurrentRawPrompt rawPrompt: String) -> [String] {
        var lines: [String] = activeTurnGoalSpecConversationContext(excludingCurrentRawPrompt: rawPrompt).compactMap { entry -> String? in
            guard let role = entry["role"] as? String,
                  let text = entry["text"] as? String else { return nil }
            return "\(role == "user" ? "用户" : "灵枢"): \(text)"
        }
        let resourceLines: [String] = activeTurnGoalSpecCurrentInputResources(matching: rawPrompt).compactMap { resource -> String? in
            guard let name = resource["name"] as? String else { return nil }
            let path = resource["path"] as? String
            return path.map { "当前附件: \(name) (\($0))" } ?? "当前附件: \(name)"
        }
        lines.append(contentsOf: resourceLines)
        return lines
    }

    /// 当前用户消息会从 conversation_context 中排除以避免重复，但它携带的附件不能一起丢掉。
    /// 这里只传资源元信息，不把 PPT/PDF 正文塞进 GoalSpec 控制面请求。
    private func activeTurnGoalSpecCurrentInputResources(matching rawPrompt: String) -> [[String: Any]] {
        let raw = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message = chatMessages.reversed().first(where: { message in
            guard message.isUser, !message.isLoading else { return false }
            let text = LingShuState.compactForModelContext(message.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text == raw && ((message.attachmentNames?.isEmpty == false) || (message.attachmentPaths?.isEmpty == false))
        }) else { return [] }

        let names = message.attachmentNames ?? []
        let paths = message.attachmentPaths ?? []
        let count = max(names.count, paths.count)
        return (0..<count).compactMap { index -> [String: Any]? in
            let path = index < paths.count ? paths[index] : ""
            let name = index < names.count ? names[index] : URL(fileURLWithPath: path).lastPathComponent
            guard !name.isEmpty || !path.isEmpty else { return nil }
            var resource: [String: Any] = ["name": name]
            if !path.isEmpty { resource["path"] = path }
            let ext = URL(fileURLWithPath: path.isEmpty ? name : path).pathExtension.lowercased()
            if !ext.isEmpty { resource["extension"] = ext }
            return resource
        }
    }

    func activeTurnGoalSpecForegroundMessages(excludingCurrentRawPrompt rawPrompt: String) -> [ChatMessage] {
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
