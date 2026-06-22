import XCTest
@testable import LingShuMac

/// 派发队列区:并发判定(纯)+ 入队/删除(状态)。
final class DispatchQueueTests: XCTestCase {

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
}
