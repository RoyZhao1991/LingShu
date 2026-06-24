import XCTest
@testable import LingShuMac

/// 派发队列区:并发判定(纯)+ 入队/删除(状态)。
final class DispatchQueueTests: XCTestCase {

    func testObviousExecutionRequestsBypassModelTriage() {
        XCTAssertTrue(
            LingShuState.isObviousExecutionRequest("把我今天待办同步到一个尚未授权的外部知识库。没有授权就不要假装完成,告诉我下一步需要什么。"),
            "明确动作+外部系统边界必须先进任务流,不能被模型误分成普通问答"
        )
        XCTAssertTrue(
            LingShuState.isObviousExecutionRequest("看看现在这个网络里有没有能无线投屏的电视/盒子,找出来告诉我"),
            "设备/网络发现是现实任务,应进入任务/权限/队列机制"
        )
        XCTAssertTrue(
            LingShuState.isObviousExecutionRequest("在目录 /tmp/lingshu 写 add.py,实现 add(a,b) 并运行测试"),
            "指定路径和产出物的执行请求必须进入任务流"
        )
        XCTAssertTrue(
            LingShuState.isObviousExecutionRequest("总结我刚才附件里的三条待办,用三点列表回答。"),
            "附件总结/分析是新的可执行目标,不能被上一条等待中的任务劫持"
        )
    }

    func testExplanationQuestionsStayInChatLane() {
        XCTAssertFalse(LingShuState.isObviousExecutionRequest("什么是 HTTP 第 3 问"))
        XCTAssertFalse(LingShuState.isObviousExecutionRequest("介绍一下你自己"))
        XCTAssertFalse(LingShuState.isObviousExecutionRequest("为什么搞个简单计算器还要我来定?"))
    }

    func testOneSentenceAdviceStaysInChatLane() {
        XCTAssertFalse(
            LingShuState.isObviousExecutionRequest("给我一句话提醒如何避免任务切换混乱。"),
            "一句话提醒是普通答复,不能被硬门误判为系统提醒/落盘任务"
        )
        XCTAssertFalse(
            LingShuState.isObviousExecutionRequest("用一句话说明执行记录有什么用。"),
            "一句话说明是普通答复,不应过度产物化"
        )
        XCTAssertTrue(
            LingShuState.isObviousExecutionRequest("明天提醒我开会"),
            "真正的提醒/日程动作仍应允许进入任务流"
        )
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
