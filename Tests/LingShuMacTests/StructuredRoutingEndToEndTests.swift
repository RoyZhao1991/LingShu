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

    @MainActor
    func testCompletedDispatchedThreadCannotBecomeRoutingCandidateOrSkipGoalSpec() {
        let state = LingShuState()
        state.chatMessages = []
        state.taskExecutionRecords = [
            LingShuTaskExecutionRecord(
                id: "completed-weclaw",
                title: "配置 WeClaw",
                prompt: "启动微信桥接",
                status: .completed,
                summary: "已完成",
                participants: [],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                messages: []
            ),
            LingShuTaskExecutionRecord(
                id: "waiting-report",
                title: "生成报告",
                prompt: "生成报告",
                status: .waitingForUser,
                summary: "等待用户选择格式",
                participants: [],
                createdAt: Date(timeIntervalSince1970: 3),
                updatedAt: Date(timeIntervalSince1970: 4),
                messages: []
            )
        ]
        state.agentSubTaskRecords = [
            "task-old": "completed-weclaw",
            "task-waiting": "waiting-report"
        ]
        state.chatMessages = [
            .init(speaker: "灵枢", text: "WeClaw 已完成", isUser: false, taskRecordID: "completed-weclaw"),
            .init(speaker: "灵枢", text: "请选择报告格式", isUser: false, taskRecordID: "waiting-report")
        ]

        let context = state.buildTriageContext()

        XCTAssertFalse(context.threads.contains { $0.recordID == "completed-weclaw" },
                       "已完成的旧线程只能作为历史，不能接管新输入")
        XCTAssertTrue(context.threads.contains { $0.recordID == "waiting-report" },
                      "真实等待用户的线程仍应参与归属判断")
        XCTAssertFalse(LingShuState.canRouteInputToExistingThread(status: .completed))
        XCTAssertFalse(LingShuState.canRouteInputToExistingThread(status: .answered))
        XCTAssertTrue(LingShuState.canRouteInputToExistingThread(status: .waitingForUser))
        XCTAssertTrue(LingShuState.canRouteInputToExistingThread(status: .needsRevision))
    }
}
