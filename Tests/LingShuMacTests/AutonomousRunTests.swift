import XCTest
@testable import LingShuMac

final class AutonomousRunTests: XCTestCase {
    actor RecordingSession: LingShuAgentSessioning {
        var resumedAnswers: [String] = []
        nonisolated var isBlocked: Bool { false }
        var turnsUsed = 0
        var toolInvocations: [String] = []
        var messages: [LingShuAgentMessage] = []
        func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {}
        func send(_ userText: String) async -> LingShuAgentRunResult { .completed(text: "ok") }
        func resume(_ answer: String) async -> LingShuAgentRunResult {
            resumedAnswers.append(answer)
            return .completed(text: "resumed")
        }
        func resumedAnswerSnapshot() -> [String] { resumedAnswers }
        func continueLoop() async -> LingShuAgentRunResult { .completed(text: "continued") }
        func injectCorrection(_ text: String) -> Bool { false }
        func injectBriefing(_ text: String) {}
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-autonomous-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEnvironmentProbeWarnsWhenFullAutonomyLacksFullExecutionPermission() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = LingShuAutonomousEnvironmentProbe().run(input: .init(
            workingDirectory: directory.path,
            modelProvider: "DeepSeek",
            modelName: "deepseek-chat",
            isModelConnected: true,
            modelConnectionState: "已连接",
            executionPermissionMode: .sandbox,
            requireHumanApproval: false,
            permissionLevel: .full,
            voiceOutputEnabled: true,
            voiceWakeListeningEnabled: true,
            memoryDigestAvailable: true,
            onlineAgentCount: 11,
            runningAgentCount: 0,
            pendingAgentCount: 11
        ))

        XCTAssertTrue(report.canRun)
        XCTAssertEqual(report.items.first { $0.id == "workspace" }?.level, .pass)
        XCTAssertEqual(report.items.first { $0.id == "artifact-root" }?.level, .pass)
        XCTAssertEqual(report.items.first { $0.id == "permission" }?.level, .warning)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("LingShuAutonomousRuns", isDirectory: true).path
        ))
    }

    func testRunbookPlannerBuildsPresentationFlowFromObjective() {
        let environment = LingShuAutonomousEnvironmentReport(generatedAt: Date(), items: [
            .init(id: "workspace", title: "工作区", level: .pass, detail: "ok"),
            .init(id: "model", title: "模型通道", level: .pass, detail: "ok")
        ])

        let runbook = LingShuAutonomousRunbookPlanner().plan(
            objective: "明天晚上学校课题规划汇报，3分钟，灵枢自主完成材料、汇报和答疑",
            permissionLevel: .delegated,
            environment: environment,
            memoryStatus: "已读取主线程记忆。"
        )

        XCTAssertTrue(runbook.missingInformation.isEmpty)
        XCTAssertTrue(runbook.capabilityHints.contains("汇报设计"))
        XCTAssertTrue(runbook.expectedArtifacts.contains("答疑库"))
        XCTAssertTrue(runbook.reviewGates.contains("时间控制"))
        XCTAssertTrue(runbook.steps.contains { $0.id == "live-qa" })
    }

    func testSelfCheckFailsWhenEnvironmentCannotRunAndWarnsOnMissingInformation() {
        let environment = LingShuAutonomousEnvironmentReport(generatedAt: Date(), items: [
            .init(id: "workspace", title: "工作区", level: .failed, detail: "缺少工作区")
        ])
        let runbook = LingShuAutonomousRunbook(
            objective: "做一次汇报",
            assumptions: [],
            missingInformation: ["截止时间", "汇报时长"],
            capabilityHints: ["规划"],
            expectedArtifacts: ["讲稿"],
            reviewGates: ["人工接管可用"],
            steps: [
                .init(id: "objective", title: "目标建模", owner: "灵枢", detail: "确认目标。", status: .waiting)
            ]
        )

        let selfCheck = LingShuAutonomousSelfCheckRunner().run(environment: environment, runbook: runbook)

        XCTAssertEqual(selfCheck.items.first { $0.id == "environment" }?.level, .failed)
        XCTAssertEqual(selfCheck.items.first { $0.id == "clarification" }?.level, .warning)
        XCTAssertEqual(selfCheck.failedCount, 1)
    }

    @MainActor
    func testStandingPersonBlockedReplyRendersResumableChoiceCard() async throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRunRecordID = rid
        state.autonomousRun = .init(
            id: "standing-test",
            objective: "",
            phase: .running,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "在岗",
            startedAt: Date(),
            updatedAt: Date()
        )
        let prompt = LingShuRouteChoicePrompt(
            question: "这一步需要你授权或提供前提才能继续:外部系统 API Key",
            options: [
                .init(label: "确认授权,继续"),
                .init(label: "暂不授权"),
                .init(label: "改用替代方案")
            ]
        )
        let envelope = LingShuState.askChoiceEnvelope(prompt).encodedPrompt

        await state.finishAutonomousRun(result: .blocked(question: envelope), recordID: rid)

        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == rid })
        XCTAssertEqual(record.status, .waitingForUser)
        XCTAssertEqual(record.taskOutcome, .waitingForUser)
        let bubble = try XCTUnwrap(state.chatMessages.last { $0.taskRecordID == rid && !$0.isUser })
        XCTAssertNotNil(bubble.choices)
        XCTAssertTrue(bubble.choices?.options.contains(where: { $0.label.contains("确认授权") }) ?? false)
        XCTAssertNil(bubble.awaitingInputForRecordID, "在岗/自主卡片点击应回到自主待答复续接,不能误走派发任务续接")
    }

    @MainActor
    func testStandingStructuredUserInputBecomesChoiceCard() async throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRunRecordID = rid
        state.autonomousRun = .init(
            id: "standing-completed-prereq",
            objective: "",
            phase: .running,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "在岗",
            startedAt: Date(),
            updatedAt: Date()
        )

        let reply = """
        {
          "reply": "我查了一下,目前没有找到今天的待办事项数据；同步到外部知识库还缺少必要前提。",
          "completion": {
            "status": "waiting_for_user",
            "reason": "缺少待办来源和外部知识库授权",
            "needs_user": true
          },
          "user_input": {
            "required": true,
            "question": "请补充今天待办的来源，并提供外部知识库授权或选择替代方案。",
            "options": [
              {"label": "我已补充，继续", "detail": "我已经提供待办来源和必要授权。"},
              {"label": "先停在这里", "detail": "当前任务先暂停。"},
              {"label": "改用替代方案", "detail": "不写入外部知识库，先输出本地整理结果。"}
            ]
          },
          "OAuth": null
        }
        """

        await state.finishAutonomousRun(result: .completed(text: reply), recordID: rid)

        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == rid })
        XCTAssertEqual(record.status, .waitingForUser, "在岗路径里,结构化 user_input 声明缺前提时必须收口成待用户,不能伪装成已回答")
        XCTAssertEqual(record.taskOutcome, .waitingForUser)
        let bubble = try XCTUnwrap(state.chatMessages.last { $0.taskRecordID == rid && !$0.isUser })
        XCTAssertNotNil(bubble.choices)
        XCTAssertTrue(bubble.text.contains("请补充今天待办的来源"))
        XCTAssertTrue(bubble.choices?.options.contains(where: { $0.label.contains("我已补充") }) ?? false)
        XCTAssertFalse(bubble.text.contains("\"user_input\""), "UI 只能展示 reply/question,不能把 JSON 协议露给用户")
    }

    @MainActor
    func testStandingPlainPrerequisiteTextDoesNotDriveChoiceCard() async throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRunRecordID = rid
        state.autonomousRun = .init(
            id: "standing-plain-prereq",
            objective: "",
            phase: .running,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "在岗",
            startedAt: Date(),
            updatedAt: Date()
        )

        let reply = """
        我查了一下,目前没有找到今天的待办事项数据。
        另外,目标外部知识库未授权,也没有账号或凭据。
        所以现在无法把待办同步过去。
        """

        await state.finishAutonomousRun(result: .completed(text: reply), recordID: rid)

        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == rid })
        XCTAssertEqual(record.status, .answered, "普通文本不允许靠关键词触发待用户/授权流程;必须来自完整 JSON 字段")
        XCTAssertNotEqual(record.taskOutcome, .waitingForUser)
        let bubble = try XCTUnwrap(state.chatMessages.last { $0.taskRecordID == rid && !$0.isUser })
        XCTAssertNil(bubble.choices)
    }

    func testPendingAutonomousQuestionOnlyConsumesAttachmentsWhenItAskedForFiles() {
        XCTAssertFalse(
            LingShuState.pendingAutonomousQuestionAcceptsAttachment("这一步需要你授权或提供前提才能继续:外部系统 API Key"),
            "授权/凭据类待答复不应吞掉下一条带附件的新任务"
        )
        XCTAssertTrue(
            LingShuState.pendingAutonomousQuestionAcceptsAttachment("请上传或拖入要分析的文件,我会继续处理。")
        )
    }

    @MainActor
    func testStopAutonomousRunFullyClearsStandingPersonLifecycle() async throws {
        let state = LingShuState()
        let session = RecordingSession()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRun = .init(
            id: "standing-stop-lifecycle",
            objective: "",
            phase: .running,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "在岗",
            startedAt: Date(),
            updatedAt: Date()
        )
        state.autonomousRunRecordID = rid
        state.autonomousSessionHolder = session
        state.autonomousPendingQuestion = "需要你确认后继续。"
        state.standingStreamingBubbleID = UUID()
        state.pendingStandingKickoff = "待启动任务"
        state.suspendedAutonomousRecordID = rid
        state.suspendedAutonomousReason = "模型通道暂停"
        let generationBeforeStop = state.autonomousRunGeneration

        state.stopAutonomousRun()

        XCTAssertEqual(state.autonomousRun.phase, .idle)
        XCTAssertFalse(state.isStandingPersonOnDuty)
        XCTAssertNil(state.autonomousRunTask)
        XCTAssertNil(state.autonomousRunRecordID)
        XCTAssertNil(state.autonomousSessionHolder)
        XCTAssertNil(state.autonomousPendingQuestion)
        XCTAssertNil(state.standingStreamingBubbleID)
        XCTAssertNil(state.pendingStandingKickoff)
        XCTAssertNil(state.suspendedAutonomousRecordID)
        XCTAssertNil(state.suspendedAutonomousReason)
        XCTAssertGreaterThan(state.autonomousRunGeneration, generationBeforeStop)
    }

    @MainActor
    func testStaleAutonomousFinishCannotReviveIdleRunAfterStop() async throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRun = .idle

        await state.finishAutonomousRun(result: .completed(text: "旧回合晚到"), recordID: rid)

        XCTAssertEqual(state.autonomousRun.phase, .idle)
        XCTAssertFalse(state.isStandingPersonOnDuty)
        XCTAssertFalse(state.chatMessages.contains { $0.taskRecordID == rid && $0.text.contains("旧回合晚到") })
    }

    @MainActor
    func testAutonomousPendingQuestionDoesNotConsumeVoiceLikeStandaloneRequest() async throws {
        let state = LingShuState()
        let session = RecordingSession()
        let rid = state.createTaskExecutionRecord(for: "独立运行待答复")
        defer {
            state.autonomousRun = .idle
            state.autonomousRunRecordID = nil
            state.autonomousPendingQuestion = nil
            state.autonomousSessionHolder = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRun = .init(
            id: "auto-pending-voice-objective-guard",
            objective: "",
            phase: .paused,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "待答复",
            startedAt: Date(),
            updatedAt: Date()
        )
        state.autonomousRunRecordID = rid
        state.autonomousPendingQuestion = "需要你提供外部知识库授权或 API Key 后才能继续。"
        state.autonomousSessionHolder = session

        let visible = "灵枢,这是一条语音入口压测。听到后用一句话说:语音入口可用。"
        let ack = state.handleAutonomousAnswerIfNeeded(
            prompt: visible,
            visiblePrompt: visible,
            taskRecordID: nil,
            hasAttachments: false
        )

        XCTAssertNil(ack, "一句话回答/播报类新请求不能被旧待答复吞掉")
        let resumed = await session.resumedAnswerSnapshot()
        XCTAssertEqual(resumed, [])
    }

    @MainActor
    func testAutonomousPendingQuestionDoesNotConsumeGroundedTurnBecauseExpandedPromptMentionsContinue() async throws {
        let state = LingShuState()
        let session = RecordingSession()
        let rid = state.createTaskExecutionRecord(for: "独立运行待答复")
        defer {
            state.autonomousRun = .idle
            state.autonomousRunRecordID = nil
            state.autonomousPendingQuestion = nil
            state.autonomousSessionHolder = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRun = .init(
            id: "auto-pending-attachment-guard",
            objective: "",
            phase: .paused,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "待答复",
            startedAt: Date(),
            updatedAt: Date()
        )
        state.autonomousRunRecordID = rid
        state.autonomousPendingQuestion = "需要你提供外部系统授权或 API Key 后才能继续。"
        state.autonomousSessionHolder = session

        let visible = "总结我刚才附件里的三条待办,用三点列表回答。"
        let expanded = """
        \(visible)

        【附件元信息】
        - meeting_note.md @ /tmp/meeting_note.md

        【附件使用规则】
        如果用户要求读取、预览、演示、修改或基于附件继续工作,优先使用本轮附件。
        """

        let ack = state.handleAutonomousAnswerIfNeeded(
            prompt: expanded,
            visiblePrompt: visible,
            taskRecordID: nil,
            hasAttachments: true
        )

        XCTAssertNil(ack, "附件新回合不能因为模型 prompt 附带规则里的“继续”被自主待答复吞掉")
        let resumed = await session.resumedAnswerSnapshot()
        XCTAssertEqual(resumed, [])
        XCTAssertNotNil(state.autonomousPendingQuestion, "未接管时 pending question 应保留,等待用户真正回答")
    }

    @MainActor
    func testAutonomousPendingQuestionDoesNotConsumeStandaloneObjective() async throws {
        let state = LingShuState()
        let session = RecordingSession()
        let rid = state.createTaskExecutionRecord(for: "独立运行待答复")
        defer {
            state.autonomousRun = .idle
            state.autonomousRunRecordID = nil
            state.autonomousPendingQuestion = nil
            state.autonomousSessionHolder = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRun = .init(
            id: "auto-pending-standalone-objective-guard",
            objective: "",
            phase: .paused,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "待答复",
            startedAt: Date(),
            updatedAt: Date()
        )
        state.autonomousRunRecordID = rid
        state.autonomousPendingQuestion = "需要你提供外部知识库授权或 API Key 后才能继续。"
        state.autonomousSessionHolder = session

        let visible = "看看现在这台电脑周围有哪些可发现的外设和投屏设备,只做发现和分类,不要要求我提供账号。"
        let ack = state.handleAutonomousAnswerIfNeeded(
            prompt: visible,
            visiblePrompt: visible,
            taskRecordID: nil,
            hasAttachments: false
        )

        XCTAssertNil(ack, "无附件的新完整目标也不能被自主待答复吞掉")
        let resumed = await session.resumedAnswerSnapshot()
        XCTAssertEqual(resumed, [])
        XCTAssertNotNil(state.autonomousPendingQuestion)
    }

    @MainActor
    func testStandingPausedStateLetsGroundedNewTurnPassThroughWhenItIsNotPendingAnswer() async throws {
        let state = LingShuState()
        let session = RecordingSession()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.autonomousRun = .idle
            state.autonomousRunRecordID = nil
            state.autonomousPendingQuestion = nil
            state.autonomousSessionHolder = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRun = .init(
            id: "standing-paused-grounded-turn",
            objective: "",
            phase: .paused,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "待答复",
            startedAt: Date(),
            updatedAt: Date()
        )
        state.autonomousRunRecordID = rid
        state.autonomousPendingQuestion = "需要你提供外部系统授权或 API Key 后才能继续。"
        state.autonomousSessionHolder = session

        let visible = "总结我刚才附件里的三条待办,用三点列表回答。"
        let expanded = """
        用户上传了以下文件，请基于它们的真实内容来理解、读取、修改、预览、演示或按需交付:
        - meeting_note.md @ /tmp/meeting_note.md

        用户指令：
        \(visible)
        """

        let consumed = state.handleStandingPersonInputIfNeeded(
            prompt: expanded,
            visiblePrompt: visible,
            taskRecordID: nil,
            hasAttachments: true
        )

        XCTAssertNil(consumed, "暂停态来自旧待答复时,带附件的新目标必须放行到主线程 active turn,不能被暂停态吞掉")
    }

    @MainActor
    func testStandingPausedStateLetsStandaloneObjectivePassThroughWhenItIsNotPendingAnswer() async throws {
        let state = LingShuState()
        let session = RecordingSession()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.autonomousRun = .idle
            state.autonomousRunRecordID = nil
            state.autonomousPendingQuestion = nil
            state.autonomousSessionHolder = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.autonomousRun = .init(
            id: "standing-paused-standalone-objective",
            objective: "",
            phase: .paused,
            permissionLevel: .full,
            environment: nil,
            selfCheck: nil,
            runbook: nil,
            statusLine: "待答复",
            startedAt: Date(),
            updatedAt: Date()
        )
        state.autonomousRunRecordID = rid
        state.autonomousPendingQuestion = "需要你提供外部知识库授权或 API Key 后才能继续。"
        state.autonomousSessionHolder = session

        let visible = "看看现在这台电脑周围有哪些可发现的外设和投屏设备,只做发现和分类,不要要求我提供账号。"
        let consumed = state.handleStandingPersonInputIfNeeded(
            prompt: visible,
            visiblePrompt: visible,
            taskRecordID: nil,
            hasAttachments: false
        )

        XCTAssertNil(consumed, "暂停态来自旧待答复时,无附件的新完整目标也必须放行到主线程 active turn")
    }
}
