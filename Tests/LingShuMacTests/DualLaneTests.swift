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
}
