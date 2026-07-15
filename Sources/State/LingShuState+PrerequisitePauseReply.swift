import Foundation

struct LingShuPrerequisitePauseReplyContext: Equatable, Sendable {
    var taskTitle: String
    var originalRequest: String
    var userChoice: String
    var missingPrerequisites: [String]
    var existingArtifacts: [String]
}

@MainActor
extension LingShuState {
    private static let prerequisitePauseReplyFallback =
        "当前任务已经暂停，已有结果会保留。需要继续时，补齐缺少的前提或从任务记录中接着推进即可。"

    func prerequisitePauseReplyContext(
        recordID: String,
        answer: String
    ) -> LingShuPrerequisitePauseReplyContext {
        guard let record = taskExecutionRecords.first(where: { $0.id == recordID }) else {
            return .init(
                taskTitle: "当前任务",
                originalRequest: "",
                userChoice: answer.isEmpty ? "暂停" : answer,
                missingPrerequisites: [],
                existingArtifacts: []
            )
        }

        var prerequisites = record.gapAnalysis?.blockingGaps.map { gap in
            [gap.missing, gap.fillPath]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "；补齐方式：")
        } ?? []
        if let authorization = record.gapAnalysis?.OAuth?.normalized {
            let authorizationSummary = [authorization.question, authorization.reason]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "；")
            if !authorizationSummary.isEmpty { prerequisites.append(authorizationSummary) }
        }

        let artifacts = record.artifacts.map { artifact in
            let title = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? artifact.location : "\(title)：\(artifact.location)"
        }
        return .init(
            taskTitle: record.goalSpec?.objective ?? record.title,
            originalRequest: record.prompt,
            userChoice: answer.isEmpty ? "暂停" : answer,
            missingPrerequisites: prerequisites,
            existingArtifacts: artifacts
        )
    }

    nonisolated static func prerequisitePauseReplyPrompt(
        _ context: LingShuPrerequisitePauseReplyContext
    ) -> String {
        let prerequisites = context.missingPrerequisites.isEmpty
            ? "(没有更多结构化信息)"
            : context.missingPrerequisites.map { "- \($0)" }.joined(separator: "\n")
        let artifacts = context.existingArtifacts.isEmpty
            ? "(尚无登记产物)"
            : context.existingArtifacts.map { "- \($0)" }.joined(separator: "\n")
        return """
        用户已经明确选择暂停当前任务。状态机已完成暂停、释放执行槽并保留已有结果；你只负责决定如何向用户解释，不能继续执行任务，也不能改变等待用户的状态。

        请以灵枢身份自然回复 1–3 句：结合具体任务说明现在停在哪里、保留了什么，以及以后怎样接着推进。不要复述固定模板，不要要求用户再次选择，不要声称任务已完成，不要编造不存在的结果或前提。若上下文不足，就简洁确认暂停。

        任务目标：\(context.taskTitle)
        原始请求：\(context.originalRequest.isEmpty ? "(未记录)" : context.originalRequest)
        用户选择：\(context.userChoice)
        尚缺前提：
        \(prerequisites)
        已有产物：
        \(artifacts)
        """
    }

    private func generatedPrerequisitePauseReply(
        context: LingShuPrerequisitePauseReplyContext,
        recordID: String
    ) async -> String? {
        if let override = prerequisitePauseReplyComposerOverride {
            let text = await override(context)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        let session = LingShuAgentSession(
            id: "pause-\(UUID().uuidString.prefix(6))",
            system: LingShuPersona.system("你正在向用户说明一个已经安全暂停的任务。只输出自然、准确的面向用户回复，不执行工具，不改变任务状态。"),
            tools: [],
            model: controlPlaneModelAdapter(.prerequisitePauseComposer, taskRecordID: recordID),
            maxTurns: 1
        )
        guard case .completed(let raw) = await session.send(Self.prerequisitePauseReplyPrompt(context)) else {
            return nil
        }
        let visible = LingShuTaskMessageFormatting.sanitize(
            LingShuStructuredModelOutput.visibleText(from: LingShuReasoningText.stripThinkTags(raw))
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }

    func composePrerequisitePauseReply(
        context: LingShuPrerequisitePauseReplyContext,
        recordID: String,
        bubbleID: UUID
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let generated = await self.generatedPrerequisitePauseReply(context: context, recordID: recordID)
            let reply = generated ?? Self.prerequisitePauseReplyFallback

            // 用户可能在这次短模型调用返回前已经补齐前提并续跑。迟到的暂停说明只能作废，
            // 绝不能把恢复中的任务重新写回 waitingForUser，也不能留下还在转圈的旧气泡。
            guard self.taskExecutionRecords.first(where: { $0.id == recordID })?.status == .waitingForUser else {
                self.chatMessages.removeAll { $0.id == bubbleID && $0.isLoading }
                return
            }

            if let index = self.chatMessages.firstIndex(where: { $0.id == bubbleID }) {
                self.chatMessages[index].text = reply
                self.chatMessages[index].isLoading = false
                self.chatMessages[index].thinkingPreview = nil
            } else {
                self.chatMessages.append(.init(speaker: "灵枢", text: reply, isUser: false, taskRecordID: recordID))
            }
            self.appendTaskRecordMessage(
                recordID,
                actor: "灵枢",
                role: generated == nil ? "暂停说明兜底" : "暂停说明",
                kind: generated == nil ? .warning : .result,
                text: reply
            )
            _ = self.commitTaskThreadState(
                recordID: recordID,
                status: .waitingForUser,
                phase: .waiting,
                summary: reply,
                persist: false,
                trace: false
            )
            self.persistTaskExecutionRecords()
        }
    }
}
