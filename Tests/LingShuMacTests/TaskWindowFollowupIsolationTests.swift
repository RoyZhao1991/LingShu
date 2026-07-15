import XCTest
@testable import LingShuMac

/// **任务窗口追问的线程隔离**(用户定调 2026-06-25):窗口里的追问始终走这条记录自己的隔离会话,**绝不落主会话**。
/// 核心保证:不论该记录有没有现存隔离子会话,追问都不进主问答线(`pendingChatTurnIDs`/`runMainAgentTurn`)。
@MainActor
final class TaskWindowFollowupIsolationTests: XCTestCase {
    private func assertTaskWindowStartedOrReported(
        _ state: LingShuState,
        recordID: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stillRunning = state.dispatchedTaskBubbles[recordID] != nil
        let record = state.taskExecutionRecordLookup.first { $0.id == recordID }
        let hasNonUserRecordProgress = record?.messages.contains { $0.kind != .user } ?? false
        let hasAssistantBubble = state.chatMessages.contains {
            $0.taskRecordID == recordID && !$0.isUser && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.isLoading)
        }
        XCTAssertTrue(stillRunning || hasNonUserRecordProgress || hasAssistantBubble, message, file: file, line: line)
    }

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
        assertTaskWindowStartedOrReported(
            state,
            recordID: rid,
            "纠正没被在飞循环接住 → 应兜底重新派发隔离会话续跑或可见收口(不石沉大海、要有执行+回复)")
        XCTAssertFalse(state.batchInterruptRequested, "兜底时复位 batchInterrupt,防泄漏卡后续验收")
    }

    /// 子线程统一交互入口(对齐 codex):没有在飞循环时,`continueTaskThread` 兜底重新起隔离会话续跑,绝不石沉大海/落主会话。
    func testContinueTaskThreadReEngagesWhenIdle() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "演示这份PPT并答疑")
        state.continueTaskThread("把这个PPT改一下，体现整体架构", recordID: rid)
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        assertTaskWindowStartedOrReported(
            state,
            recordID: rid,
            "子线程消息没被在飞循环接住 → 兜底重新起隔离会话续跑或可见收口(始终有执行+回复,对齐 codex)")
        XCTAssertTrue(state.pendingChatTurnIDs.isEmpty, "续的是隔离线程,绝不落主会话问答线")
        XCTAssertFalse(state.batchInterruptRequested, "复位 batchInterrupt 防泄漏")
    }

    func testFollowupOnRecordWithSubSessionStaysIsolated() {
        let state = LingShuState()
        state.markAllTaskThreadsRead()
        let rid = state.createTaskExecutionRecord(for: "派发任务Y")
        if let index = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) {
            state.taskExecutionRecords[index].status = .partial
        }
        // 有现存隔离子会话映射 → 走 resume 分支,续同一条隔离会话。
        state.agentSubTaskRecords["task-abc123"] = rid

        state.submitTaskFollowup("继续推进", recordID: rid)

        // 走隔离 resume:追问落进这条记录(窗口),不进主会话问答线、不另起主回合。
        XCTAssertTrue(state.pendingChatTurnIDs.isEmpty, "有隔离子会话时追问 resume 那条会话,绝不落主会话")
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == rid }?.status, .running,
                       "终态线程续跑应立即恢复本记录的执行中状态")
        XCTAssertTrue(state.activeTaskThreadRecordIDs.contains(rid), "续跑应登记独立子线程运行态")
        XCTAssertNil(state.dispatchedTaskBubbles[rid], "线程内续跑不应制造主对话占位气泡")
        let rec = state.taskExecutionRecords.first { $0.id == rid }
        XCTAssertTrue(rec?.messages.contains { $0.text.contains("继续推进") } ?? false,
                      "追问应记进这条任务自己的记录(窗口可见)")
    }

    /// **续接守住原始工作目录(2026-06-30 修 cancel+resume 丢上下文)**:goal 被 GoalSpec 抽象掉了字面目录,
    /// 续接上下文必须从原始请求把 `/tmp/lingshu-e2e`、`scraper.py` 这些字面目录/文件名带回来。
    func testResumeContextCarriesOriginalRequestDirectory() {
        let ctx = LingShuState.resumeContextPrompt(
            originalRequest: "在 /tmp/lingshu-e2e 下写一个 Python 爬虫框架 scraper.py,带单测。",
            summary: nil,
            goal: "在指定目录创建一个功能完整的爬虫框架文件",   // GoalSpec 抽象,丢了字面目录
            resumeInput: "接着上面的进度继续写完")
        XCTAssertTrue(ctx.contains("/tmp/lingshu-e2e"), "续接上下文必须保留原始请求里的字面目录")
        XCTAssertTrue(ctx.contains("scraper.py"), "也要保留字面文件名")
        XCTAssertTrue(ctx.contains("接着上面的进度继续写完"), "续接指令要在")
    }

    /// 已有产出物是任务续接最可靠的落点:模型不应重新扫目录猜文件。
    func testResumeContextCarriesRegisteredArtifacts() {
        let artifact = LingShuTaskExecutionArtifact(
            title: "ledger.txt",
            location: "/tmp/lingshu-stage9-close/ledger.txt",
            producer: "测试"
        )
        let ctx = LingShuState.resumeContextPrompt(
            originalRequest: "创建一个账本文件。",
            summary: "账本文件已创建并验证。",
            goal: "维护账本文件",
            artifacts: [artifact],
            resumeInput: "追加一行 followup")
        XCTAssertTrue(ctx.contains("已登记产出物"), "续接上下文应显式列出已有产出物")
        XCTAssertTrue(ctx.contains("/tmp/lingshu-stage9-close/ledger.txt"), "续接应保留真实文件路径")
        XCTAssertTrue(ctx.contains("追加一行 followup"), "用户新的续接指令不能丢")
    }

    /// 原始请求为空(老记录无 prompt)→ 退回纯续接指令,不崩、不加空壳。
    func testResumeContextEmptyOriginalFallsBack() {
        XCTAssertEqual(LingShuState.resumeContextPrompt(originalRequest: nil, summary: nil, goal: nil, resumeInput: "继续"), "继续")
        XCTAssertEqual(LingShuState.resumeContextPrompt(originalRequest: "   ", summary: "", goal: nil, resumeInput: "继续"), "继续")
    }
}
