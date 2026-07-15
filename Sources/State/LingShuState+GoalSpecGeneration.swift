import Foundation

/// GoalSpec 的重新生成、结构硬门与失败收口。
/// 与上下文装配/历史检索分开,避免目标认知主文件重新膨胀。
@MainActor
extension LingShuState {
    /// 主界面只表达用户能理解的状态；具体生成协议、重试次数和失败原因留在 trace 中。
    nonisolated static var goalSpecUserProgressMessage: String { "理解中…" }

    nonisolated static var goalSpecUnavailableUserMessage: String {
        let attempts = LingShuGoalSpecGenerationPolicy.maximumAttempts
        return "⚠️ 核心目标生成未完成:已进行 \(attempts) 次模型生成/修复,仍未获得完整可执行的 GoalSpec。本轮未启动任务,也没有使用默认目标降级执行;请稍后重试。"
    }

    /// 只要开启 GoalSpec 且这是新的 active turn,结构化目标缺失就必须阻断。
    /// reply 复用既有任务的 GoalSpec;用户显式关闭功能时保持原有行为。
    nonisolated static func mustBlockForMissingGoalSpec(
        enabled: Bool,
        isNewActiveTurn: Bool,
        goalSpec: LingShuGoalSpec?
    ) -> Bool {
        enabled && isNewActiveTurn && goalSpec == nil
    }

    /// 对同一份完整上下文进行最多三次模型生成/修复。每次都新建会话，
    /// 输出协议按真实通道能力协商，只有通过结构校验的结果才能交给下游。
    func generateValidatedGoalSpec(
        modelRequest: String,
        taskRecordID: String?,
        allowUnresolvedReference: Bool,
        onProgress: ((Int, Int, String) -> Void)?
    ) async -> LingShuGoalSpec? {
        let timeouts = LingShuGoalSpecGenerationPolicy.timeouts(
            for: LingShuGoalSpecParser.systemPrompt + "\n" + modelRequest
        )
        let protocolName = selectedModelPreset?.protocolName ?? "OpenAI 兼容"
        let requestFormat = LingShuModelGateway().requestFormat(
            provider: modelProvider,
            endpoint: endpoint,
            protocolName: protocolName
        )
        var preferToolSubmission = LingShuStructuredGoalSpecCapability.shouldAttemptToolSubmission(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: protocolName,
            format: requestFormat
        )
        var lastIssue = "未知原因"
        var previousOutput: String?
        var previousIssue: String?

        for (offset, timeout) in timeouts.enumerated() {
            guard !Task.isCancelled else { return nil }
            let attempt = offset + 1
            let total = timeouts.count
            let useToolSubmission = preferToolSubmission
            let isRepair = previousOutput != nil
            onProgress?(attempt, total, Self.goalSpecUserProgressMessage)

            let transportInstruction = useToolSubmission
                ? "必须调用且只调用 submit_goal_spec 提交最终结果；不要把 GoalSpec 放在普通正文里。工具参数就是最终 GoalSpec。"
                : "本轮没有结构化提交工具。严格只输出一个完整 GoalSpec JSON，不要输出解释、思考过程或 markdown 围栏。"
            let system = LingShuGoalSpecParser.systemPrompt + """


            【本轮结构化输出契约】
            - \(transportInstruction)
            - 所有字段都必须出现；数组字段即使为空也必须写 []；枚举只能使用契约列出的原值。
            - 不得因为信息不足省略字段：把不确定性写进 reference_confidence/open_questions。
            """
            let prompt: String
            if let previousOutput, let previousIssue {
                prompt = goalSpecRepairRequest(
                    originalContext: modelRequest,
                    previousOutput: previousOutput,
                    validationIssue: previousIssue
                )
            } else {
                prompt = modelRequest
            }
            let adapter = controlPlaneModelAdapter(
                .goalSpec,
                taskRecordID: taskRecordID,
                timeoutOverride: timeout
            )
            let submissionBox = LingShuGoalSpecSubmissionBox(
                allowUnresolvedReference: allowUnresolvedReference
            )
            let tools = useToolSubmission
                ? [LingShuGoalSpecToolContract.makeTool(box: submissionBox)]
                : []
            let session = LingShuAgentSession(
                id: "goalspec-\(UUID().uuidString.prefix(6))",
                system: system,
                tools: tools,
                model: adapter,
                maxTurns: 1
            )
            let result = await session.send(prompt)
            guard !Task.isCancelled else { return nil }

            let submission = await submissionBox.snapshot()
            if let accepted = submission.accepted {
                appendTrace(
                    kind: .system,
                    actor: "目标认知",
                    title: attempt > 1 ? "GoalSpec 模型修复成功" : "GoalSpec 结构化生成成功",
                    detail: "第 \(attempt)/\(total) 次通过 submit_goal_spec 结构校验(timeout=\(Int(timeout))s)。"
                )
                return accepted
            }
            if let raw = submission.raw {
                previousOutput = raw
                let validationIssue = submission.issue ?? "submit_goal_spec 参数未通过结构校验"
                previousIssue = validationIssue
                lastIssue = validationIssue
                // 工具已经被真实调用，说明本通道支持该协议；下一轮继续让同一大脑按 Schema 修复。
                preferToolSubmission = true
            }

            switch result {
            case .completed(let text):
                let cleaned = LingShuReasoningText.stripThinkTags(text)
                guard let candidate = LingShuGoalSpecParser.parse(cleaned) else {
                    lastIssue = "模型正文不是可解析的 GoalSpec JSON"
                    previousOutput = text
                    previousIssue = lastIssue
                    // 请求接受了 tools 却只回普通正文，不能据此永久判不支持；本轮仅改走纯 JSON 修复。
                    if useToolSubmission { preferToolSubmission = false }
                    appendGoalSpecOutputDiagnostic(raw: text, cleaned: cleaned, issue: lastIssue, attempt: attempt, total: total)
                    break
                }
                if let issue = LingShuGoalSpecParser.executionReadinessIssue(
                    candidate,
                    allowUnresolvedReference: allowUnresolvedReference
                ) {
                    lastIssue = issue
                    previousOutput = text
                    previousIssue = issue
                    if useToolSubmission { preferToolSubmission = false }
                    appendGoalSpecOutputDiagnostic(raw: text, cleaned: cleaned, issue: issue, attempt: attempt, total: total)
                    break
                }
                if attempt > 1 || !useToolSubmission {
                    appendTrace(
                        kind: .system,
                        actor: "目标认知",
                        title: isRepair ? "GoalSpec 模型修复成功" : "GoalSpec JSON 生成成功",
                        detail: "第 \(attempt)/\(total) 次正文通过结构校验(timeout=\(Int(timeout))s)。"
                    )
                }
                return candidate
            case .interrupted(let reason):
                lastIssue = "模型调用中断:\(String(reason.prefix(180)))"
                if useToolSubmission,
                   LingShuStructuredGoalSpecCapability.explicitlyRejectsToolSubmission(reason) {
                    LingShuStructuredGoalSpecCapability.markToolSubmissionUnsupported(
                        provider: modelProvider,
                        model: modelName,
                        endpoint: endpoint,
                        protocolName: protocolName
                    )
                    preferToolSubmission = false
                    lastIssue = "当前通道明确拒绝结构化工具提交；已按通道能力记录，下次改用同模型 JSON 生成"
                    appendTrace(
                        kind: .warning,
                        actor: "目标认知",
                        title: "结构化提交协议降级",
                        detail: "通道键=\(modelProvider)/\(modelName)/\(protocolName)；服务端明确拒绝 tools/function calling，本轮继续使用同一大脑的 JSON 生成，不生成默认目标。"
                    )
                } else if useToolSubmission,
                          LingShuModelServiceFailure.decodeReason(reason)?.kind == .requestInvalid {
                    // 原因未明确指向 tools，不形成持久能力结论；只让本轮换协议再试。
                    preferToolSubmission = false
                }
            case .blocked(let question):
                lastIssue = "目标解析器意外进入等待:\(String(question.prefix(180)))"
            case .maxTurnsReached(let lastText):
                if submission.raw == nil {
                    lastIssue = useToolSubmission
                        ? "模型未提交 submit_goal_spec"
                        : "目标解析达到回合上限:\(String(lastText.prefix(180)))"
                    previousIssue = lastIssue
                    if !lastText.isEmpty { previousOutput = lastText }
                }
            }
            appendTrace(
                kind: .system,
                actor: "目标认知",
                title: attempt < total ? "GoalSpec 未完成·准备重新生成" : "GoalSpec 未完成",
                detail: "第 \(attempt)/\(total) 次(timeout=\(Int(timeout))s):\(lastIssue)"
            )
        }
        appendTrace(
            kind: .system,
            actor: "目标认知",
            title: "GoalSpec 生成失败·已阻止执行",
            detail: "已完成 \(timeouts.count) 次模型生成/修复,仍未获得完整 GoalSpec。最后原因:\(lastIssue)。不得生成默认 question/task 继续执行。"
        )
        return nil
    }

    private func goalSpecRepairRequest(
        originalContext: String,
        previousOutput: String,
        validationIssue: String
    ) -> String {
        let payload: [String: Any] = [
            "type": "lingshu_goal_spec_repair",
            "instruction": "Use the complete original_context again. Correct the previous output according to validation_issue; do not change the user's target or discard referenced entities/resources.",
            "validation_issue": validationIssue,
            "previous_output": String(previousOutput.prefix(16_000)),
            "original_context": originalContext
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return originalContext
        }
        return text
    }

    private func appendGoalSpecOutputDiagnostic(
        raw: String,
        cleaned: String,
        issue: String,
        attempt: Int,
        total: Int
    ) {
        let sample = cleaned
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(320)
        appendTrace(
            kind: .warning,
            actor: "目标认知",
            title: "GoalSpec 输出校验未通过",
            detail: "第 \(attempt)/\(total) 次；问题=\(issue)；rawChars=\(raw.count)；cleanChars=\(cleaned.count)；清洗后样本=\(sample)"
        )
    }

    /// GoalSpec 重试耗尽的统一收口:显式告知、记录失败,但绝不调度任何执行器。
    func markGoalSpecPreflightFailure(
        request: String,
        recordID: String? = nil,
        bubbleID: UUID? = nil,
        appendChatIfMissing: Bool = true
    ) {
        let message = Self.goalSpecUnavailableUserMessage
        var updatedBubble = false
        if let bubbleID, let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            chatMessages[index].text = message
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            updatedBubble = true
        }
        if !updatedBubble, appendChatIfMissing {
            chatMessages.append(.init(speaker: "灵枢", text: message, isUser: false, taskRecordID: recordID))
        }
        if let recordID {
            appendTaskRecordMessage(
                recordID,
                actor: "目标认知",
                role: "GoalSpec",
                kind: .warning,
                text: "核心目标重新生成耗尽,执行管线已阻断。原始请求:\(String(request.prefix(240)))"
            )
            finishTaskRecord(recordID, status: .failed, summary: "GoalSpec 生成失败,未启动任务执行。")
            dispatchedTaskBubbles[recordID] = nil
        }
        missionStatus = "核心目标生成失败,本轮已停止。"
        appendTrace(
            kind: .system,
            actor: "目标认知",
            title: "执行入口已阻断",
            detail: "GoalSpec 重试耗尽,未建立默认 question/task,未进入任务执行。"
        )
    }

    nonisolated static func activeTurnGoalSpecNeedsHistoryFallback(
        _ spec: LingShuGoalSpec,
        currentInput: String
    ) -> Bool {
        if spec.referenceConfidence == .high {
            if spec.referenceScope == .currentInput { return false }
            return spec.referenceEvidence.isEmpty || activeTurnGoalSpecObjectiveLooksGeneric(spec.objective)
        }
        if spec.referenceConfidence == .medium || spec.referenceConfidence == .low { return true }
        if spec.referenceScope.escapesDefaultAnchor || spec.referenceScope == .defaultAnchor || spec.referenceScope == .memory {
            return true
        }
        return activeTurnInputLooksReferential(currentInput)
    }

    private nonisolated static func activeTurnGoalSpecObjectiveLooksGeneric(_ objective: String) -> Bool {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let genericRefs = [
            "之前的分析", "之前的内容", "前面的分析", "前面的内容", "相关内容", "相关分析",
            "那个", "这个", "那些", "这些", "那份", "这份", "那几个", "那三个", "上述"
        ]
        return genericRefs.contains { text.contains($0) }
    }

    private nonisolated static func activeTurnInputLooksReferential(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return false }
        let signals = [
            "继续", "接着", "刚才", "前面", "之前", "上次", "上一", "那", "这",
            "那个", "这个", "那些", "这些", "那三", "那几", "那份", "这份",
            "它", "他们", "她们", "其", "相关", "原来", "更准确", "复核", "基于"
        ]
        return signals.contains { trimmed.contains($0) }
    }
}
