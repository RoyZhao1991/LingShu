import XCTest
@testable import LingShuMac

/// 第③站 → 内核闸门 → 第⑤站 的本地端到端走线。
///
/// 不调用真实模型,只验证控制面是否只接受结构化 JSON,以及 route 结果如何进入上下文装配。
final class StructuredRoutingEndToEndTests: XCTestCase {

    @MainActor
    func testReplyRouteContinuesExistingTaskWithTaskMemory() {
        let state = LingShuState()
        let threads = [
            TriageThread(label: "T1", recordID: "task-record-1", summary: "⏳正等你回答:请选择演示方式")
        ]

        let decision = LingShuState.parseContextResolverDecision(
            #"{"route":"reply","thread":"T1","confidence":"high"}"#,
            threads: threads
        )
        let gate = state.kernelGate(decision, goalSpec: nil)
        let plan = LingShuContextAssemblyPlan.continueExistingTask(
            recordID: decision.replyRecordID ?? "",
            source: "structured_route_reply",
            reason: "resume_dispatched_thread"
        )

        XCTAssertEqual(decision.kind, .reply)
        XCTAssertEqual(decision.replyRecordID, "task-record-1")
        XCTAssertEqual(gate, .execute)
        XCTAssertEqual(plan.strategy, .continueExistingTask)
        XCTAssertTrue(plan.includeTaskMemory)
        XCTAssertEqual(plan.toolScope, .task)
        XCTAssertTrue(plan.traceLine.contains("strategy=continue_existing_task"))
    }

    @MainActor
    func testNoneRouteFallsToMainActiveTurnAndLetsBrainDecide() {
        let state = LingShuState()
        let threads = [
            TriageThread(label: "T1", recordID: "task-record-1", summary: "⏳正等你回答:请选择演示方式")
        ]

        let decision = LingShuState.parseContextResolverDecision(
            #"{"route":"none","confidence":"high"}"#,
            threads: threads
        )
        let gate = state.kernelGate(decision, goalSpec: nil)
        let plan = LingShuContextAssemblyPlan.mainActiveTurn(
            source: "structured_route_none",
            reason: "brain_decides_reply_or_task"
        )

        XCTAssertEqual(decision.kind, .chat)
        XCTAssertNil(decision.replyRecordID)
        XCTAssertEqual(gate, .execute)
        XCTAssertEqual(plan.strategy, .mainActiveTurn)
        XCTAssertTrue(plan.includeMainRecentContext)
        XCTAssertFalse(plan.includeTaskMemory)
        XCTAssertEqual(plan.toolScope, .full)
        XCTAssertTrue(plan.traceLine.contains("strategy=main_active_turn"))
    }

    @MainActor
    func testDirtyRouteOutputCannotHijackAnyTask() {
        let state = LingShuState()
        let threads = [
            TriageThread(label: "T1", recordID: "task-record-1", summary: "⏳正等你回答:请选择演示方式")
        ]

        let decision = LingShuState.parseContextResolverDecision(
            #"这句话里虽然出现 {"route":"reply","thread":"T1","confidence":"high"} 但不是完整 JSON"#,
            threads: threads
        )
        let gate = state.kernelGate(decision, goalSpec: nil)
        let plan = LingShuContextAssemblyPlan.mainActiveTurn(
            source: "invalid_structured_route",
            reason: "dirty_output_falls_back_to_brain"
        )

        XCTAssertEqual(decision.kind, .chat)
        XCTAssertNil(decision.replyRecordID)
        XCTAssertEqual(gate, .execute)
        XCTAssertEqual(plan.strategy, .mainActiveTurn)
        XCTAssertFalse(plan.includeTaskMemory)
    }
}
