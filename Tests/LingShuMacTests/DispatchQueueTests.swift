import XCTest
@testable import LingShuMac

/// 派发队列区:并发判定(纯)+ 入队/删除(状态)。
final class DispatchQueueTests: XCTestCase {

    func testContextResolverOnlyRoutesHighConfidenceReplies() {
        let threads = [TriageThread(label: "T1", recordID: "record-1", summary: "⏳正等你回答")]
        let decision = LingShuState.parseContextResolverDecision(
            #"{"route":"reply","thread":"T1","confidence":"high"}"#,
            threads: threads
        )

        XCTAssertEqual(decision.kind, .reply)
        XCTAssertEqual(decision.replyRecordID, "record-1")
    }

    func testContextResolverDoesNotGuessOnLowConfidenceOrMissingThread() {
        let threads = [TriageThread(label: "T1", recordID: "record-1", summary: "⏳正等你回答")]

        let low = LingShuState.parseContextResolverDecision(
            #"{"route":"reply","thread":"T1","confidence":"low"}"#,
            threads: threads
        )
        XCTAssertEqual(low.kind, .chat, "低置信不归属,交主脑按最近上下文处理")

        let missing = LingShuState.parseContextResolverDecision(
            #"{"route":"reply","thread":"T9","confidence":"high"}"#,
            threads: threads
        )
        XCTAssertEqual(missing.kind, .chat, "模型引用不存在的候选线程时不能兜到第一条,避免错接")
    }

    func testAttachmentInputContinuationGuard() {
        XCTAssertFalse(
            LingShuState.waitingQuestionAcceptsAttachment("需要你提供外部服务授权或 API Key 后才能继续。"),
            "授权/凭据类待答复不应默认吞掉下一条带附件的新任务"
        )
        XCTAssertTrue(
            LingShuState.waitingQuestionAcceptsAttachment("请上传要分析的文件或给我本机路径。")
        )
        XCTAssertTrue(
            LingShuState.attachmentInputExplicitlyContinuesPendingThread("这是你要的文件,继续刚才那件事。")
        )
        XCTAssertFalse(
            LingShuState.attachmentInputExplicitlyContinuesPendingThread("总结我刚才附件里的三条待办。"),
            "附件本身是新证据,没有明确指代旧任务时不应被待答复线程劫持"
        )
        XCTAssertTrue(
            LingShuState.inputMentionsGroundedEvidence("总结我刚才附件里的三条待办。"),
            "即使附件托盘状态没带出,证据型输入也要受归属保护"
        )
        XCTAssertFalse(
            LingShuState.groundedInputCanAnswerPendingQuestion(
                visiblePrompt: "总结我刚才附件里的三条待办。",
                pendingQuestion: "请上传要分析的文件或给我本机路径。",
                hasAttachments: true
            ),
            "围绕附件提出新目标时,不能仅因旧问题接受文件就续回旧线程"
        )
        XCTAssertTrue(
            LingShuState.groundedInputCanAnswerPendingQuestion(
                visiblePrompt: "已上传 1 个文件",
                pendingQuestion: "请上传要分析的文件或给我本机路径。",
                hasAttachments: true
            ),
            "旧问题明确要文件,而用户只是交附件时,可以续回旧线程"
        )
    }

    func testPendingQuestionGuardDoesNotConsumeStandaloneObjective() {
        let pending = "需要你提供外部知识库授权或 API Key 后才能继续。"

        XCTAssertFalse(
            LingShuState.inputCanAnswerPendingQuestion(
                visiblePrompt: "看看现在这台电脑周围有哪些可发现的外设和投屏设备,只做发现和分类,不要要求我提供账号。",
                pendingQuestion: pending,
                hasAttachments: false
            ),
            "受保护前提等待中,新的完整目标不能被当成旧问题答案"
        )
        XCTAssertFalse(
            LingShuState.inputCanAnswerPendingQuestion(
                visiblePrompt: "灵枢,这是一条语音入口压测。听到后用一句话说:语音入口可用。",
                pendingQuestion: pending,
                hasAttachments: false
            ),
            "让灵枢说一句话/回答一句话也是新的完整目标,不能被旧授权问题吞掉"
        )
        XCTAssertTrue(
            LingShuState.inputCanAnswerPendingQuestion(
                visiblePrompt: "确认授权,继续。",
                pendingQuestion: pending,
                hasAttachments: false
            ),
            "真正回答授权/凭据前提时仍应续回旧线程"
        )
    }

    @MainActor
    func testStandaloneObjectiveDoesNotRouteToUnrelatedPendingMainQuestion() async throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部知识库")
        defer {
            state.pendingMainQuestionRecordID = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.pendingMainQuestionRecordID = rid
        state.appendTaskRecordMessage(
            rid,
            actor: "灵枢",
            role: "待用户",
            kind: .warning,
            text: "需要你提供外部知识库授权或 API Key 后才能继续。"
        )

        let decision = await state.classifyDispatch(
            "看看现在这台电脑周围有哪些可发现的外设和投屏设备,只做发现和分类,不要要求我提供账号。",
            hasAttachments: false
        )

        XCTAssertEqual(decision.kind, .chat)
        XCTAssertNil(decision.replyRecordID, "无附件的新完整目标也不能续回无关的授权等待线程")
    }

    @MainActor
    func testAttachmentInputDoesNotRouteToUnrelatedPendingMainQuestion() async throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部知识库")
        defer {
            state.pendingMainQuestionRecordID = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.pendingMainQuestionRecordID = rid
        state.appendTaskRecordMessage(
            rid,
            actor: "灵枢",
            role: "待用户",
            kind: .warning,
            text: "需要你提供外部知识库授权或 API Key 后才能继续。"
        )

        let decision = await state.classifyDispatch(
            """
            总结我刚才附件里的三条待办,用三点列表回答。

            【附件元信息】
            - meeting_note.md @ /tmp/meeting_note.md
            """,
            hasAttachments: true
        )

        XCTAssertEqual(decision.kind, .chat)
        XCTAssertNil(decision.replyRecordID, "带附件的新 grounded turn 不应续回无关的授权等待线程")
    }

    @MainActor
    func testAttachmentRoutingUsesVisiblePromptInsteadOfExpandedModelPrompt() async throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "等待外部系统授权")
        defer {
            state.pendingMainQuestionRecordID = nil
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.pendingMainQuestionRecordID = rid
        state.appendTaskRecordMessage(
            rid,
            actor: "灵枢",
            role: "待用户",
            kind: .warning,
            text: "需要你提供外部系统授权或 API Key 后才能继续。"
        )

        let visible = "总结我刚才附件里的三条待办,用三点列表回答。"
        let expanded = """
        \(visible)

        【附件元信息】
        - meeting_note.md @ /tmp/meeting_note.md

        【附件使用规则】
        如果用户要求读取、预览、演示、修改或基于附件继续工作,优先使用本轮附件。
        """
        let decision = await state.classifyDispatch(expanded, hasAttachments: true, visiblePrompt: visible)

        XCTAssertEqual(decision.kind, .chat)
        XCTAssertNil(decision.replyRecordID, "路由归属只能看用户原话;附件规则里的“继续”不能把输入错接到无关待答复线程")
    }

    @MainActor
    func testKernelGateDoesNotHardDispatchChatFromActionHintCompatibilityField() {
        let state = LingShuState()
        let decision = LingShuState.DispatchDecision(
            kind: .chat,
            goal: nil,
            replyRecordID: nil,
            confidence: .high,
            actionHint: true
        )

        XCTAssertEqual(state.kernelGate(decision, goalSpec: nil), .execute)
    }

    func testActiveTurnPreflightCapabilityOnlyForTaskAndInteraction() {
        XCTAssertTrue(LingShuState.goalKindNeedsCapabilityPreflight(.task))
        XCTAssertTrue(LingShuState.goalKindNeedsCapabilityPreflight(.interaction))
        XCTAssertFalse(LingShuState.goalKindNeedsCapabilityPreflight(.question))
        XCTAssertFalse(LingShuState.goalKindNeedsCapabilityPreflight(.unknown))
        XCTAssertFalse(LingShuState.goalKindNeedsCapabilityPreflight(nil))
    }

    func testActiveTurnPreflightTraceUsesStructuredFormat() {
        let trace = LingShuState.activeTurnPreflightTrace(
            stage: "bind_record",
            route: "active_turn",
            recordID: "record-1",
            goalKind: .task,
            capabilityPreflight: true,
            requirementsCount: 2,
            hasGap: true,
            reason: "goal_kind_requires_capability_check"
        )

        XCTAssertTrue(trace.contains("flow=active_turn"))
        XCTAssertTrue(trace.contains("stage=bind_record"))
        XCTAssertTrue(trace.contains("route=active_turn"))
        XCTAssertTrue(trace.contains("record=record-1"))
        XCTAssertTrue(trace.contains("goalKind=task"))
        XCTAssertTrue(trace.contains("capabilityPreflight=on"))
        XCTAssertTrue(trace.contains("requirements=2"))
        XCTAssertTrue(trace.contains("gap=present"))
        XCTAssertTrue(trace.contains("reason=goal_kind_requires_capability_check"))
    }

    func testShouldQueueWhenAtOrOverCapacity() {
        XCTAssertFalse(LingShuState.shouldQueueDispatch(running: 0, capacity: 3))
        XCTAssertFalse(LingShuState.shouldQueueDispatch(running: 2, capacity: 3))
        XCTAssertTrue(LingShuState.shouldQueueDispatch(running: 3, capacity: 3), "满 3 → 进队列")
        XCTAssertTrue(LingShuState.shouldQueueDispatch(running: 5, capacity: 3))
        XCTAssertTrue(LingShuState.shouldQueueDispatch(running: 1, capacity: 1))
    }

    @MainActor
    func testEnqueueThenDeleteBeforeDispatch() {
        let state = LingShuState()
        XCTAssertTrue(state.queuedDispatchTasks.isEmpty)
        state.enqueueDispatchTask(prompt: "任务A", goal: "做A", goalSpec: nil, gap: nil, requirements: [])
        state.enqueueDispatchTask(prompt: "任务B", goal: "做B", goalSpec: nil, gap: nil, requirements: [])
        XCTAssertEqual(state.queuedDispatchTasks.count, 2, "并发满时进队列区等待,不立即派发")
        // 队列区里删除一条(尚未派发,可删)。
        let firstID = state.queuedDispatchTasks[0].id
        state.removeQueuedDispatchTask(id: firstID)
        XCTAssertEqual(state.queuedDispatchTasks.count, 1)
        XCTAssertEqual(state.queuedDispatchTasks.first?.prompt, "任务B", "删掉 A 后剩 B")
        // 入队不创建任务记录(没进主窗口);删除后也不残留。
        XCTAssertFalse(state.taskExecutionRecords.contains { $0.prompt == "任务A" }, "入队不提前建记录/进主窗口")
    }

    @MainActor
    func testQueuedItemCarriesPreflightCognition() {
        let state = LingShuState()
        let spec = LingShuGoalSpec(objective: "同步到 Notion", kind: .task, successCriteria: ["写入成功"])
        state.enqueueDispatchTask(prompt: "同步", goal: "同步", goalSpec: spec, gap: nil,
                                  requirements: [.init(verb: .externalSystemWrite, target: "Notion")])
        let item = state.queuedDispatchTasks.first
        XCTAssertEqual(item?.goalSpec?.objective, "同步到 Notion", "入队带前置认知,晋级时直接绑定免重派生")
        XCTAssertEqual(item?.requirements.first?.verb, .externalSystemWrite)
    }

    @MainActor
    func testQueuedDispatchKeepsVisiblePromptSeparateFromModelPrompt() {
        let state = LingShuState()
        let modelPrompt = "附件正文:继续/记录/演示\n\n用户指令：\n演示这份 PPT"

        state.enqueueDispatchTask(
            prompt: modelPrompt,
            visiblePrompt: "演示这份 PPT",
            goal: "演示这份 PPT",
            goalSpec: nil,
            gap: nil,
            requirements: []
        )

        let item = state.queuedDispatchTasks.first
        XCTAssertEqual(item?.prompt, modelPrompt)
        XCTAssertEqual(item?.visiblePrompt, "演示这份 PPT")
    }

    @MainActor
    func testQueuedTaskReusesAdjacentAnswerBubble() {
        let state = LingShuState()
        let q1 = ChatMessage(speaker: "你", text: "任务1", isUser: true)
        let a1 = ChatMessage(speaker: "灵枢", text: "执行中", isUser: false, isLoading: true)
        let q2 = ChatMessage(speaker: "你", text: "任务2", isUser: true)
        let a2 = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [q1, a1, q2, a2]

        state.enqueueDispatchTask(prompt: "任务2", goal: "做任务2", goalSpec: nil, gap: nil,
                                  requirements: [], existingBubbleID: a2.id)

        XCTAssertEqual(state.chatMessages.map(\.id), [q1.id, a1.id, q2.id, a2.id],
                       "入队必须复用用户消息后的占位答复,不能删掉后追加到聊天尾部")
        XCTAssertFalse(state.chatMessages[3].isLoading)
        XCTAssertTrue(state.chatMessages[3].text.contains("已加入队列区等待"))
        XCTAssertEqual(state.queuedDispatchTasks.first?.bubbleID, a2.id)
    }

    @MainActor
    func testPromoteQueuedTaskKeepsSameAnswerBubble() {
        let state = LingShuState()
        let answer = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [
            ChatMessage(speaker: "你", text: "任务2", isUser: true),
            answer
        ]
        state.enqueueDispatchTask(prompt: "任务2", goal: "做任务2", goalSpec: nil, gap: nil,
                                  requirements: [], existingBubbleID: answer.id)

        let item = state.queuedDispatchTasks.removeFirst()
        let rid = state.createTaskExecutionRecord(for: item.prompt)
        state.dispatchIsolatedTask(prompt: item.prompt, taskRecordID: rid, goal: item.goal, existingBubbleID: item.bubbleID)

        XCTAssertEqual(state.chatMessages.count, 2, "晋级执行也应复用原答复气泡,不能再追加一条执行气泡")
        XCTAssertEqual(state.chatMessages.last?.id, answer.id)
        XCTAssertEqual(state.chatMessages.last?.taskRecordID, rid)
        XCTAssertTrue(state.chatMessages.last?.isLoading ?? false)
    }

    @MainActor
    func testInactiveDispatchedBubbleDoesNotHoldQueueSlot() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "需要本地知识检索")
        let bubble = ChatMessage(speaker: "灵枢", text: "等待用户授权", isUser: false, taskRecordID: recordID)
        state.chatMessages.append(bubble)
        state.dispatchedTaskBubbles[recordID] = bubble.id
        if let idx = state.taskExecutionRecords.firstIndex(where: { $0.id == recordID }) {
            state.taskExecutionRecords[idx].status = .waitingForUser
        }

        state.pruneInactiveDispatchedTaskBubbles()

        XCTAssertNil(state.dispatchedTaskBubbles[recordID], "待用户/终态任务不能继续占派发串行槽,否则后续任务会永久排队")
    }
}
