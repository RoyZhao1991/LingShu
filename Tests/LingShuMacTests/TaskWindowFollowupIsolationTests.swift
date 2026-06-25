import XCTest
@testable import LingShuMac

/// **任务窗口追问的线程隔离**(用户定调 2026-06-25):窗口里的追问始终走这条记录自己的隔离会话,**绝不落主会话**。
/// 核心保证:不论该记录有没有现存隔离子会话,追问都不进主问答线(`pendingChatTurnIDs`/`runMainAgentTurn`)。
@MainActor
final class TaskWindowFollowupIsolationTests: XCTestCase {

    func testFollowupOnRecordWithoutSubSessionReDispatchesIsolatedNotMain() {
        let state = LingShuState()
        // 造一条"主线程直答"式记录:已答复、且**没有**隔离子会话映射(复现 bug 场景)。
        let rid = state.createTaskExecutionRecord(for: "后台守候续跑:Claude CLI OAuth")
        if let idx = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) {
            state.taskExecutionRecords[idx].status = .answered
        }
        XCTAssertNil(state.agentSubTaskRecords.first(where: { $0.value == rid })?.key,
                     "前提:这条记录没有隔离子会话(主线程直答记录)")
        XCTAssertTrue(state.pendingChatTurnIDs.isEmpty)

        state.submitTaskFollowup("你是谁", recordID: rid)

        // 修复后:窗口追问为这条记录**重新派发一条隔离会话**(dispatchedTaskBubbles 同步置位),
        // **绝不**进主会话问答线 → 线程隔离不被破坏。
        XCTAssertNotNil(state.dispatchedTaskBubbles[rid], "窗口追问应重新派发隔离会话,而非落主会话")
        XCTAssertTrue(state.pendingChatTurnIDs.isEmpty, "追问绝不进主会话问答线(不污染主线程上下文)")
    }

    /// 干预纠正兜底(修「子线程收到没回复」):任务显示「执行中」但 agent 循环其实已结束(如演示交给播放循环)→
    /// injectCorrection 没被在飞循环接住 → 不能让纠正石沉大海,要兜底当新指令重新起隔离会话续跑(产出执行+回复)。
    func testInterjectCorrectionFallsBackWhenNoLoopRunning() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "演示这份PPT并答疑")
        // 没有任何在飞会话(main/autonomous/子会话都没)→ 注入返回 false、没人消费。
        XCTAssertNil(state.agentSubTaskRecords.first(where: { $0.value == rid })?.key)
        state.interjectCorrection("把这个PPT改一下，体现整体架构", recordID: rid)
        // 等异步注入检查 + 兜底续跑跑完。
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(state.dispatchedTaskBubbles[rid],
                        "纠正没被在飞循环接住 → 应兜底重新派发隔离会话续跑(不石沉大海、要有执行+回复)")
        XCTAssertFalse(state.batchInterruptRequested, "兜底时复位 batchInterrupt,防泄漏卡后续验收")
    }

    /// 子线程统一交互入口(对齐 codex):没有在飞循环时,`continueTaskThread` 兜底重新起隔离会话续跑,绝不石沉大海/落主会话。
    func testContinueTaskThreadReEngagesWhenIdle() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "演示这份PPT并答疑")
        state.continueTaskThread("把这个PPT改一下，体现整体架构", recordID: rid)
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(state.dispatchedTaskBubbles[rid],
                        "子线程消息没被在飞循环接住 → 兜底重新起隔离会话续跑(始终有执行+回复,对齐 codex)")
        XCTAssertTrue(state.pendingChatTurnIDs.isEmpty, "续的是隔离线程,绝不落主会话问答线")
        XCTAssertFalse(state.batchInterruptRequested, "复位 batchInterrupt 防泄漏")
    }

    func testFollowupOnRecordWithSubSessionStaysIsolated() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "派发任务Y")
        // 有现存隔离子会话映射 → 走 resume 分支,续同一条隔离会话。
        state.agentSubTaskRecords["task-abc123"] = rid

        state.submitTaskFollowup("继续推进", recordID: rid)

        // 走隔离 resume:追问落进这条记录(窗口),不进主会话问答线、不另起主回合。
        XCTAssertTrue(state.pendingChatTurnIDs.isEmpty, "有隔离子会话时追问 resume 那条会话,绝不落主会话")
        let rec = state.taskExecutionRecords.first { $0.id == rid }
        XCTAssertTrue(rec?.messages.contains { $0.text.contains("继续推进") } ?? false,
                      "追问应记进这条任务自己的记录(窗口可见)")
    }
}
