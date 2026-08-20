import XCTest
@testable import LingShuMac

/// 「1+1=2 双线」(用户定调 2026-06-23):问答线与任务线各自串行、独立并行;
/// 问答线**等待中(未执行)的问答可删、执行中的不可删**;任务线串行(maxConcurrent=1)+ 可删队列区。
@MainActor
final class DualLaneTests: XCTestCase {

    private func ling() -> ChatMessage { .init(speaker: "灵枢", text: "", isUser: false, isLoading: true) }
    private func you(_ t: String) -> ChatMessage { .init(speaker: "你", text: t, isUser: true) }

    func testWaitingChatTurnDeletableExecutingNot() {
        let state = LingShuState()
        let q1 = you("Q1"); let a1 = ling()
        let q2 = you("Q2"); let a2 = ling()
        let q3 = you("Q3"); let a3 = ling()
        state.chatMessages = [q1, a1, q2, a2, q3, a3]
        state.pendingChatTurnIDs = [a1.id, a2.id, a3.id]
        state.executingChatTurnID = a1.id   // a1 执行中

        // 执行中的不可删。
        XCTAssertFalse(state.canDeletePendingChatTurn(a1.id), "执行中不可删")
        state.deletePendingChatTurn(bubbleID: a1.id)
        XCTAssertEqual(state.chatMessages.count, 6, "执行中删除无效")

        // 等待中的可删 → 连同它的问题一起删。
        XCTAssertTrue(state.canDeletePendingChatTurn(a2.id), "等待中可删")
        state.deletePendingChatTurn(bubbleID: a2.id)
        XCTAssertEqual(state.chatMessages.map(\.id), [q1.id, a1.id, q3.id, a3.id], "删掉 q2+a2,其余不动")
        XCTAssertFalse(state.pendingChatTurnIDs.contains(a2.id))
        XCTAssertTrue(state.cancelledChatTurnIDs.contains(a2.id), "标记取消→轮到执行点会跳过")

        // 不在 pending 里的乱删无效。
        let bogus = UUID()
        state.deletePendingChatTurn(bubbleID: bogus)
        XCTAssertEqual(state.chatMessages.count, 4)

        // a3 仍等待可删。
        XCTAssertTrue(state.canDeletePendingChatTurn(a3.id))
        state.deletePendingChatTurn(bubbleID: a3.id)
        XCTAssertEqual(state.chatMessages.map(\.id), [q1.id, a1.id], "只剩执行中的 q1+a1")
    }

    func testDeleteOnlyRemovesPrecedingUserMessage() {
        let state = LingShuState()
        // 答复前不是用户消息的情况(如系统/上岗招呼):只删答复占位,不误删前一条。
        let sys = ling()   // 非用户的前置消息
        let a = ling()
        state.chatMessages = [sys, a]
        state.pendingChatTurnIDs = [a.id]
        state.executingChatTurnID = nil
        state.deletePendingChatTurn(bubbleID: a.id)
        XCTAssertEqual(state.chatMessages.map(\.id), [sys.id], "前一条非用户消息不误删")
    }

    func testTaskLaneIsSerialCapacityOne() {
        // 任务线串行:容量 1 → 第 2 条起进队列(信息池)。
        XCTAssertFalse(LingShuState.shouldQueueDispatch(running: 0, capacity: 1), "第1条直接派发")
        XCTAssertTrue(LingShuState.shouldQueueDispatch(running: 1, capacity: 1), "第2条进队列")
        XCTAssertTrue(LingShuState.shouldQueueDispatch(running: 2, capacity: 1))
    }

    func testCanDeleteFalseForNonPending() {
        let state = LingShuState()
        XCTAssertFalse(state.canDeletePendingChatTurn(UUID()), "不在 pending 列表 → 不可删")
    }

    // 卡住任务的待输入状态:问题保留在原气泡,统一输入框直达隔离会话续跑(不经分诊)。
    func testDispatchedTaskAwaitingInputInBubble() {
        let state = LingShuState()
        let rec = LingShuTaskExecutionRecord(id: "r1", title: "斐波那契", prompt: "P", status: .running, summary: "",
                                             participants: [], createdAt: Date(), updatedAt: Date(), messages: [])
        state.taskExecutionRecords = [rec]
        let bubble = ChatMessage(speaker: "灵枢", text: "推进中", isUser: false, isLoading: true, taskRecordID: "r1")
        state.chatMessages = [bubble]
        state.dispatchedTaskBubbles["r1"] = bubble.id

        // 卡住 → 把气泡标成「待你输入」。
        state.markDispatchedBubbleAwaitingInput(recordID: "r1", question: "选 A 还是 B?")
        let m = state.chatMessages.first { $0.id == bubble.id }
        XCTAssertEqual(m?.awaitingInputForRecordID, "r1", "问题气泡标成待输入")
        XCTAssertEqual(m?.isLoading, false, "不再 loading")
        XCTAssertTrue(m?.text.contains("选 A 还是 B?") == true, "问题内容保留在原气泡")
        XCTAssertNil(state.dispatchedTaskBubbles["r1"], "气泡定稿,旧映射清掉(答复时新建续跑气泡)")

        // 统一输入框直答 → 冻结原问题,用户答案与后续助手输出各自追加新气泡。
        state.agentSubTaskRecords["sub1"] = "r1"
        state.answerDispatchedTask(recordID: "r1", answer: "A")
        let frozenQuestion = state.chatMessages.first { $0.id == bubble.id }
        XCTAssertNil(frozenQuestion?.awaitingInputForRecordID, "答后冻结原问题")
        XCTAssertTrue(frozenQuestion?.text.contains("选 A 还是 B?") == true, "答后不得改写原问题")

        let answerIndexes = state.chatMessages.indices.filter {
            state.chatMessages[$0].isUser && state.chatMessages[$0].text == "A"
        }
        XCTAssertEqual(answerIndexes.count, 1, "用户答案只能登记一次")
        let continuationID = try? XCTUnwrap(state.dispatchedTaskBubbles["r1"])
        let questionIndex = state.chatMessages.firstIndex { $0.id == bubble.id }
        let continuationIndex = continuationID.flatMap { id in
            state.chatMessages.firstIndex { $0.id == id }
        }
        XCTAssertNotNil(continuationIndex, "新建了续跑进度气泡")
        XCTAssertTrue(
            (questionIndex ?? .max) < (answerIndexes.first ?? .min)
                && (answerIndexes.first ?? .max) < (continuationIndex ?? .min),
            "时间线必须严格保持:问题 < 用户答案 < 新助手续跑"
        )
    }

    func testUnifiedComposerDoesNotDuplicateDispatchedAnswer() {
        let state = LingShuState()
        let rec = LingShuTaskExecutionRecord(
            id: "r2",
            title: "选择任务",
            prompt: "P",
            status: .running,
            summary: "",
            participants: [],
            createdAt: Date(),
            updatedAt: Date(),
            messages: []
        )
        state.taskExecutionRecords = [rec]
        let question = ChatMessage(
            speaker: "灵枢",
            text: "请选择 1 或 2",
            isUser: false,
            taskRecordID: "r2",
            awaitingInputForRecordID: "r2"
        )
        let answer = ChatMessage(speaker: "你", text: "2", isUser: true, taskRecordID: "r2")
        state.chatMessages = [question, answer]
        state.agentSubTaskRecords["sub2"] = "r2"

        state.answerDispatchedTask(recordID: "r2", answer: "2", appendUserMessage: false)

        XCTAssertEqual(state.chatMessages.filter { $0.isUser && $0.text == "2" }.count, 1)
        XCTAssertEqual(state.chatMessages.first?.text, "请选择 1 或 2", "旧问题必须保持原样")
        XCTAssertNil(state.chatMessages.first?.awaitingInputForRecordID)
        XCTAssertEqual(state.chatMessages[1].id, answer.id, "统一输入框生成的用户气泡保持在问题下方")
        XCTAssertFalse(state.chatMessages.last?.isUser ?? true, "恢复输出必须在用户答案下方新建助手气泡")
    }

    func testResolvedStructuredInteractionKeepsReadOnlyHistory() {
        let state = LingShuState()
        let recordID = "r3"
        let request = LingShuHumanInteractionRequest(
            id: "interaction-r3",
            kind: .question,
            title: "补充信息",
            prompt: "请选择处理方式",
            options: [
                .init(id: "1", label: "方案一", value: "1"),
                .init(id: "2", label: "方案二", value: "2")
            ]
        )
        let question = ChatMessage(
            speaker: "灵枢",
            text: request.prompt,
            isUser: false,
            taskRecordID: recordID,
            awaitingInputForRecordID: recordID,
            humanInteraction: request
        )
        state.chatMessages = [question]
        state.pendingDispatchedHumanInteractions[recordID] = request
        state.agentSubTaskRecords["sub3"] = recordID

        state.answerDispatchedTask(recordID: recordID, answer: "2", displayAnswer: "方案二")

        let frozenQuestion = state.chatMessages.first { $0.id == question.id }
        XCTAssertEqual(frozenQuestion?.humanInteraction, request, "结构化问题卡必须作为只读历史保留")
        XCTAssertEqual(frozenQuestion?.resolvedChoice, "方案二")
        XCTAssertNil(frozenQuestion?.awaitingInputForRecordID, "历史卡不得再次接收输入")
        XCTAssertEqual(state.chatMessages.filter { $0.isUser && $0.text == "方案二" }.count, 1)
    }

    func testActiveMainTurnContinuationNeverWritesBackIntoQuestionBubble() {
        let state = LingShuState()
        let question = ChatMessage(
            speaker: "灵枢",
            text: "请选择 1 或 2",
            isUser: false,
            isLoading: false,
            taskRecordID: "main-r1"
        )
        state.chatMessages = [question]
        state.activeAgentTurnBubbleID = question.id
        state.activeAgentVisibleBubbleID = question.id

        state.appendInteractionUserMessage("2", recordID: "main-r1")
        state.beginActiveMainTurnContinuation(recordID: "main-r1")

        XCTAssertEqual(state.chatMessages[0].id, question.id)
        XCTAssertEqual(state.chatMessages[0].text, "请选择 1 或 2", "主回合原问题必须冻结")
        XCTAssertTrue(state.chatMessages[1].isUser)
        XCTAssertEqual(state.chatMessages[1].text, "2")
        XCTAssertFalse(state.chatMessages[2].isUser)
        XCTAssertTrue(state.chatMessages[2].isLoading)
        XCTAssertEqual(state.activeAgentVisibleBubbleID, state.chatMessages[2].id)

        guard let visibleID = state.activeAgentVisibleBubbleID else {
            return XCTFail("必须建立新的助手流式气泡")
        }
        let streamed = String(repeating: "继续处理", count: 40)
        state.appendStreamingBubbleText(streamed, to: visibleID)
        state.flushStreamingBubbleText(for: visibleID)

        XCTAssertEqual(state.chatMessages[0].text, "请选择 1 或 2", "后续流式输出不得回写旧问题")
        XCTAssertEqual(state.chatMessages[2].text, streamed, "后续流式输出只追加到新助手气泡")
    }

    func testAnswerEmptyIsNoop() {
        let state = LingShuState()
        let before = state.chatMessages.count
        state.answerDispatchedTask(recordID: "rX", answer: "   ")
        XCTAssertEqual(state.chatMessages.count, before, "空答复无副作用")
    }
}
