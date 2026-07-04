import XCTest
@testable import LingShuMac

/// **串行输入队列**(砍掉双线并行):闸门信号 `currentlyExecutingTurn()` + 入队/删除 + 忙时 drain 不出队。
/// 出队重提交涉及真分诊/模型,属集成路径,放 live 验,不在此单测。
@MainActor
final class SerialInputQueueTests: XCTestCase {

    func testIdleStateIsNotExecuting() {
        let state = LingShuState()
        XCTAssertFalse(state.currentlyExecutingTurn(), "空闲态:没有任何回合在跑")
        XCTAssertTrue(state.pendingSerialInputs.isEmpty)
    }

    func testRunningChatTurnCountsAsExecuting() {
        let state = LingShuState()
        state.executingChatTurnID = UUID()
        XCTAssertTrue(state.currentlyExecutingTurn(), "问答线有回合在跑 → 视为在跑(新输入应入队)")
    }

    func testRunningDispatchedTaskCountsAsExecuting() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "派发任务X")
        if let idx = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) {
            state.taskExecutionRecords[idx].status = .running
        }
        state.dispatchedTaskBubbles[rid] = UUID()
        XCTAssertTrue(state.currentlyExecutingTurn(), "派发子线程在执行 → 视为在跑")
    }

    func testWaitingForUserTaskDoesNotBlock() {
        // 等用户回答的派发任务被 prune 剔除,不算"在跑"——否则答复会被入队而死锁。
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "等回答的任务")
        if let idx = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) {
            state.taskExecutionRecords[idx].status = .waitingForUser
        }
        state.dispatchedTaskBubbles[rid] = UUID()
        XCTAssertFalse(state.currentlyExecutingTurn(), "waitingForUser → 让出输入权,答复不入队")
    }

    func testEnqueueShowsBubbleAndQueuesInput() {
        let state = LingShuState()
        state.enqueueSerialInput(prompt: "排队的问句", source: .typed)
        XCTAssertEqual(state.pendingSerialInputs.count, 1)
        XCTAssertEqual(state.pendingSerialInputs.first?.prompt, "排队的问句")
        XCTAssertTrue(state.chatMessages.last?.text.contains("已排队") ?? false, "入队要在聊天里显示一条排队气泡")
    }

    func testSerialQueuePreservesVisibleInputAndAttachmentMetadata() {
        let state = LingShuState()
        let modelPrompt = "附件正文:继续/记录/演示\n\n用户指令：\n演示附件里的 PPT"
        state.enqueueSerialInput(
            prompt: modelPrompt,
            source: .typed,
            visiblePrompt: "演示附件里的 PPT",
            attachmentNames: ["demo.pptx"],
            attachmentPaths: ["/tmp/demo.pptx"]
        )

        let item = state.pendingSerialInputs.first
        XCTAssertEqual(item?.prompt, modelPrompt)
        XCTAssertEqual(item?.visiblePrompt, "演示附件里的 PPT")
        XCTAssertEqual(item?.attachmentNames, ["demo.pptx"])
        XCTAssertEqual(item?.attachmentPaths, ["/tmp/demo.pptx"])
    }

    func testDrainIsNoOpWhileBusy() {
        let state = LingShuState()
        state.executingChatTurnID = UUID()           // 有回合在跑
        state.enqueueSerialInput(prompt: "排队的问句", source: .typed)
        state.drainSerialInputsIfIdle()
        XCTAssertEqual(state.pendingSerialInputs.count, 1, "有回合在跑时不出队(严格串行)")
    }

    func testDrainIsNoOpWhenQueueEmpty() {
        let state = LingShuState()
        state.drainSerialInputsIfIdle()              // 空队列 + 空闲:什么都不做,不崩
        XCTAssertTrue(state.pendingSerialInputs.isEmpty)
    }

    func testCancelCurrentMainTurnReleasesSerialGateImmediately() {
        let state = LingShuState()
        let bubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages.append(bubble)
        state.executingChatTurnID = bubble.id
        state.pendingChatTurnIDs = [bubble.id]
        state.pendingMainTurns[bubble.id] = .init(
            bubbleID: bubble.id,
            prompt: "一个正在执行的开放问题",
            taskRecordID: nil,
            resumeBlocked: false,
            originalPromptForVerification: nil,
            startedAt: Date()
        )
        state.isModelReplying = true

        XCTAssertTrue(state.currentlyExecutingTurn())

        state.cancelCurrentCall()

        XCTAssertNil(state.executingChatTurnID, "停止后必须同步清掉当前执行标记,不能等远端 worker defer")
        XCTAssertTrue(state.pendingChatTurnIDs.isEmpty)
        XCTAssertNil(state.pendingMainTurns[bubble.id])
        XCTAssertFalse(state.currentlyExecutingTurn(), "停止完成后串行闸门应立即释放,下一条输入不应误入队")
    }

    func testCancelCurrentMainTurnPreservesProgressAndAddsStopMarker() {
        let state = LingShuState()
        let progress = "已完成第一步,正在继续处理。"
        let bubble = ChatMessage(speaker: "灵枢", text: progress, isUser: false, isLoading: true)
        state.chatMessages.append(bubble)
        state.executingChatTurnID = bubble.id
        state.pendingChatTurnIDs = [bubble.id]
        state.pendingMainTurns[bubble.id] = .init(
            bubbleID: bubble.id,
            prompt: "一个正在执行的任务",
            taskRecordID: nil,
            resumeBlocked: false,
            originalPromptForVerification: nil,
            startedAt: Date()
        )
        state.isModelReplying = true

        state.cancelCurrentCall()

        let text = state.chatMessages.first(where: { $0.id == bubble.id })?.text ?? ""
        XCTAssertTrue(text.contains(progress), "手动停止不能覆盖已有进展")
        XCTAssertTrue(text.contains("手动中止"), "手动停止应追加中止标识")
        XCTAssertFalse(state.chatMessages.first(where: { $0.id == bubble.id })?.isLoading ?? true)
    }

    func testManualStopMarkerUsesStandaloneTextForEmptyBubble() {
        XCTAssertEqual(LingShuState.textWithManualStopMarker(""), "⏹ 本轮调用已手动中止。")
    }

    func testManualStopOnTaskRecordPreservesLoadingBubbleProgress() {
        let state = LingShuState()
        let recordID = "task-stop-record"
        let progress = "子任务已经完成资料读取。"
        let bubble = ChatMessage(speaker: "灵枢", text: progress, isUser: false, isLoading: true, taskRecordID: recordID)
        state.chatMessages = [bubble]

        state.markTaskRecordManuallyStopped(recordID)

        XCTAssertTrue(state.manuallyStoppedTaskRecords.contains(recordID))
        XCTAssertEqual(state.chatMessages.first?.isLoading, false)
        XCTAssertTrue(state.chatMessages.first?.text.contains(progress) ?? false)
        XCTAssertTrue(state.chatMessages.first?.text.contains("手动中止") ?? false)
    }

    func testRemoveSerialInputDropsItAndMarksBubble() {
        let state = LingShuState()
        state.enqueueSerialInput(prompt: "要删的", source: .typed)
        let id = state.pendingSerialInputs.first!.id
        state.removeSerialInput(id: id)
        XCTAssertTrue(state.pendingSerialInputs.isEmpty, "删除后队列空")
        XCTAssertTrue(state.chatMessages.last?.text.contains("已从队列区移除") ?? false)
    }
}
