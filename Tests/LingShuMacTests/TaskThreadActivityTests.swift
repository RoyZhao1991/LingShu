import XCTest
@testable import LingShuMac

@MainActor
final class TaskThreadActivityTests: XCTestCase {
    private func makeState() -> LingShuState {
        let state = LingShuState()
        state.markAllTaskThreadsRead()
        return state
    }

    func testSubthreadRunDoesNotReplaceMainTurnStateOrCreateChatBubble() {
        let state = makeState()
        let mainRecordID = state.createTaskExecutionRecord(for: "主线程正在回答")
        let childRecordID = state.createTaskExecutionRecord(for: "子线程继续修改文档")
        state.currentAgentTurnRecordID = mainRecordID
        state.isModelReplying = true
        state.isModelExecuting = true
        if let index = state.taskExecutionRecords.firstIndex(where: { $0.id == childRecordID }) {
            state.taskExecutionRecords[index].status = .partial
        }
        let bubblesBefore = state.dispatchedTaskBubbles

        state.beginTaskThreadRun(recordID: childRecordID, summary: "子线程续跑中")

        XCTAssertEqual(state.currentAgentTurnRecordID, mainRecordID, "子线程不能覆盖主线程当前回合")
        XCTAssertTrue(state.isModelReplying, "子线程不能收口或替换主线程回复状态")
        XCTAssertTrue(state.isModelExecuting, "子线程不能收口或替换主线程执行状态")
        XCTAssertTrue(state.hasActiveModelCall, "主线程在飞状态必须保持可见")
        XCTAssertEqual(state.dispatchedTaskBubbles, bubblesBefore, "子线程运行登记不能创建或替换主对话气泡")
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == childRecordID }?.status, .running)
        XCTAssertTrue(state.activeTaskThreadRecordIDs.contains(childRecordID))

        state.finishTaskRecord(childRecordID, status: .completed, summary: "子线程修改完成")

        XCTAssertEqual(state.currentAgentTurnRecordID, mainRecordID, "子线程完成不能收口主线程当前回合")
        XCTAssertTrue(state.isModelReplying)
        XCTAssertTrue(state.isModelExecuting)
        XCTAssertTrue(state.hasActiveModelCall)
        XCTAssertFalse(state.activeTaskThreadRecordIDs.contains(childRecordID))
        XCTAssertTrue(state.isTaskThreadUnread(childRecordID), "主线程仍在跑时，子线程结果应进入被动未读提示")
    }

    func testHiddenSubthreadCompletionBecomesUnreadAndOpeningClearsIt() {
        let state = makeState()
        let recordID = state.createTaskExecutionRecord(for: "生成演讲稿")
        state.agentSubTaskRecords["task-test"] = recordID
        state.beginTaskThreadRun(recordID: recordID)

        state.finishTaskRecord(recordID, status: .completed, summary: "演讲稿已完成")

        XCTAssertFalse(state.activeTaskThreadRecordIDs.contains(recordID))
        XCTAssertTrue(state.isTaskThreadUnread(recordID))
        XCTAssertEqual(state.unreadTaskThreadCount, 1)

        state.openTaskRecord(recordID)
        XCTAssertFalse(state.isTaskThreadUnread(recordID), "打开对应线程后应清除该线程未读")
        XCTAssertEqual(state.unreadTaskThreadCount, 0)
    }

    func testVisibleSubthreadCompletionDoesNotCreateUnreadBadge() {
        let state = makeState()
        let recordID = state.createTaskExecutionRecord(for: "生成演讲稿")
        state.agentSubTaskRecords["task-visible"] = recordID
        state.openTaskRecord(recordID)
        state.beginTaskThreadRun(recordID: recordID)

        state.finishTaskRecord(recordID, status: .verified, summary: "验收通过")

        XCTAssertFalse(state.activeTaskThreadRecordIDs.contains(recordID))
        XCTAssertFalse(state.isTaskThreadUnread(recordID), "用户正在看该线程时，完成结果已经读到，不应再加未读")
    }

    func testSuccessfulStatusPartitionKeepsEveryOtherStatusInNeedsAttentionSection() {
        let successful: [LingShuTaskExecutionStatus] = [.completed, .answered, .verified]
        let needsAttention: [LingShuTaskExecutionStatus] = [
            .queued, .running, .dispatched, .needsRevision, .blocked, .suspended,
            .analyzing, .acquiringCapability, .waitingForUser, .ready, .partial, .failed
        ]

        XCTAssertTrue(successful.allSatisfy(\.isSuccessfulCompletion))
        XCTAssertTrue(needsAttention.allSatisfy { !$0.isSuccessfulCompletion })
    }
}
