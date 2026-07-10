import Foundation

/// GoalSpec 的重新生成、结构硬门与失败收口。
/// 与上下文装配/历史检索分开,避免目标认知主文件重新膨胀。
@MainActor
extension LingShuState {
    nonisolated static var goalSpecUnavailableUserMessage: String {
        let attempts = LingShuControlPlaneRole.goalSpec.generationTimeouts.count
        return "⚠️ 核心目标生成未完成:已进行 \(attempts) 次独立生成,仍未获得完整可执行的 GoalSpec。本轮未启动任务,也没有使用默认目标降级执行;请稍后重试。"
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

    /// 对同一份完整上下文进行三次独立生成。每次都新建会话,避免污染上次的中断状态;
    /// 只有通过 `executionReadinessIssue` 的结构才能交给下游。
    func generateValidatedGoalSpec(
        modelRequest: String,
        taskRecordID: String?,
        onProgress: ((Int, Int, String) -> Void)?
    ) async -> LingShuGoalSpec? {
        let timeouts = LingShuControlPlaneRole.goalSpec.generationTimeouts
        var lastIssue = "未知原因"
        for (offset, timeout) in timeouts.enumerated() {
            guard !Task.isCancelled else { return nil }
            let attempt = offset + 1
            let total = timeouts.count
            let progress = attempt == 1
                ? "正在生成核心目标(\(attempt)/\(total))…"
                : "上一次目标生成未完成,正在重新生成(\(attempt)/\(total))…"
            onProgress?(attempt, total, progress)
            let system = attempt == 1 ? LingShuGoalSpecParser.systemPrompt : LingShuGoalSpecParser.systemPrompt + """


            这是第 \(attempt) 次独立生成。上一次超时、中断或结构不完整;请仍以本轮提供的完整上下文为准,严格输出全部必填字段的单个 JSON。
            """
            let adapter = controlPlaneModelAdapter(
                .goalSpec,
                taskRecordID: taskRecordID,
                timeoutOverride: timeout
            )
            let session = LingShuAgentSession(
                id: "goalspec-\(UUID().uuidString.prefix(6))",
                system: system,
                tools: [],
                model: adapter,
                maxTurns: 1
            )
            let result = await session.send(modelRequest)
            guard !Task.isCancelled else { return nil }
            switch result {
            case .completed(let text):
                guard let candidate = LingShuGoalSpecParser.parse(LingShuReasoningText.stripThinkTags(text)) else {
                    lastIssue = "模型返回不是可解析的 GoalSpec JSON"
                    break
                }
                if let issue = LingShuGoalSpecParser.executionReadinessIssue(candidate) {
                    lastIssue = issue
                    break
                }
                if attempt > 1 {
                    appendTrace(
                        kind: .system,
                        actor: "目标认知",
                        title: "GoalSpec 重新生成成功",
                        detail: "第 \(attempt)/\(total) 次生成通过结构校验(timeout=\(Int(timeout))s)。"
                    )
                }
                return candidate
            case .interrupted(let reason):
                lastIssue = "模型调用中断:\(String(reason.prefix(180)))"
            case .blocked(let question):
                lastIssue = "目标解析器意外进入等待:\(String(question.prefix(180)))"
            case .maxTurnsReached(let lastText):
                lastIssue = "目标解析达到回合上限:\(String(lastText.prefix(180)))"
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
            detail: "已完成 \(timeouts.count) 次独立生成,仍未获得完整 GoalSpec。最后原因:\(lastIssue)。不得生成默认 question/task 继续执行。"
        )
        return nil
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
