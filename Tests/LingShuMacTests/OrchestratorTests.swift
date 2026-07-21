import XCTest
@testable import LingShuMac

/// 按目标线程 id 给不同脚本的 mock 模型(让不同子会话各跑各的剧本,验证隔离)。
private final class PerCallScriptedModel: LingShuAgentModel, @unchecked Sendable {
    private var script: [LingShuAgentModelResponse]
    private var index = 0
    init(_ script: [LingShuAgentModelResponse]) { self.script = script }
    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
        defer { index += 1 }
        return index < script.count ? script[index] : .text("(脚本耗尽)")
    }
}

private actor FixedResultSession: LingShuAgentSessioning {
    let result: LingShuAgentRunResult
    var isBlocked: Bool = false
    var turnsUsed: Int = 0
    var toolInvocations: [String] = []
    var messages: [LingShuAgentMessage] = []

    init(_ result: LingShuAgentRunResult) { self.result = result }

    func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {}
    func send(_ userText: String) async -> LingShuAgentRunResult { result }
    func resume(_ answer: String) async -> LingShuAgentRunResult { result }
    func continueLoop() async -> LingShuAgentRunResult { result }
    func injectCorrection(_ text: String) -> Bool { false }
    func injectBriefing(_ text: String) {}
}

final class OrchestratorTests: XCTestCase {

    private func session(_ id: String, _ script: [LingShuAgentModelResponse]) -> LingShuAgentSession {
        LingShuAgentSession(id: id, tools: [], model: PerCallScriptedModel(script))
    }

    // 设计点②:子会话卡住 → 摘要落账本 + 主动推送。
    func testBlockedSubReportsToLedgerAndPushes() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        let sub = session("sub-ppt", [
            .toolCalls([.init(id: "c1", name: "ask_user", argumentsJSON: "{\"question\":\"汇报时长是几分钟?\"}")])
        ])
        let result = await orch.spawn(id: "sub-ppt", objective: "做汇报PPT", session: sub)

        XCTAssertEqual(result, .blocked(question: "汇报时长是几分钟?"))
        let ledger = await orch.ledger()
        XCTAssertEqual(ledger.first?.status, .blocked)
        XCTAssertEqual(ledger.first?.blockedOn, "汇报时长是几分钟?")
        let pushes = await orch.pendingPushes()
        XCTAssertTrue(pushes.contains { $0.contains("卡住") && $0.contains("汇报时长") })
    }

    // 设计点③:凭账本把后续输入路由回卡住的子会话并续跑到完成。
    func testResumeRoutesViaLedgerAndCompletes() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        let sub = session("sub-ppt", [
            .toolCalls([.init(id: "c1", name: "ask_user", argumentsJSON: "{\"question\":\"几分钟?\"}")]),
            .text("已按10分钟生成汇报PPT")     // resume 后这一轮收尾
        ])
        _ = await orch.spawn(id: "sub-ppt", objective: "做汇报PPT", session: sub)

        // 主会话凭账本路由:只有一个卡住 → 命中它。
        let routed = await orch.routeFollowup("10分钟")
        XCTAssertEqual(routed, "sub-ppt")

        let resumed = await orch.resume(id: "sub-ppt", answer: "10分钟")
        XCTAssertEqual(resumed, .completed(text: "已按10分钟生成汇报PPT"))
        let ledger = await orch.ledger()
        XCTAssertEqual(ledger.first?.status, .completed)
        let pushes = await orch.pendingPushes()
        XCTAssertTrue(pushes.contains { $0.contains("已完成") })
    }

    func testStructuredOkAtTurnCeilingIsRecordedAsCompleted() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        let raw = #"{"reply":"分析报告已生成,并已登记复核结果。","completion":{"status":"ok","reason":"目标已达成","needs_user":false},"user_input":null,"inability":null,"OAuth":null}"#
        let result = await orch.spawn(
            id: "sub-report",
            objective: "生成分析报告并复核",
            session: FixedResultSession(.maxTurnsReached(lastText: raw))
        )

        guard case .maxTurnsReached = result else {
            return XCTFail("测试夹具应模拟会话在轮次边界返回 maxTurnsReached")
        }
        let ledger = await orch.ledger()
        XCTAssertEqual(ledger.first?.status, .completed, "结构化 completion.ok 已经是收尾信号,不能再误报未能自行收尾")
        XCTAssertEqual(ledger.first?.summary, "分析报告已生成,并已登记复核结果。")
        let pushes = await orch.pendingPushes()
        XCTAssertTrue(pushes.contains { $0.contains("已完成") })
        XCTAssertFalse(pushes.contains { $0.contains("未能自行收尾") })
    }

    func testCheckerFailureCannotBePromotedByMakerCompletionOK() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        let makerOK = #"{"reply":"maker 自述已完成","completion":{"status":"ok","reason":"maker 认为完成","needs_user":false}}"#
        let rejected = LingShuVerificationFailure.text(makerOK + "\nchecker: failed")
        _ = await orch.spawn(
            id: "sub-rejected",
            objective: "交付并验收",
            session: FixedResultSession(.maxTurnsReached(lastText: rejected))
        )

        let ledger = await orch.ledger()
        XCTAssertEqual(ledger.first?.status, .failed)
        XCTAssertTrue(ledger.first?.summary.contains(LingShuVerificationFailure.prefix) == true)
        let pushes = await orch.pendingPushes()
        XCTAssertFalse(pushes.contains { $0.contains("已完成") })
    }

    // 死锁回归:卡在 ask_user 等用户的任务**不占并发槽**——否则多条"等你补充"占满槽 → 新任务永远派不出去 = 死锁。
    func testBlockedTasksReleaseConcurrencySlots() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 2)
        let a = session("sub-a", [.toolCalls([.init(id: "c1", name: "ask_user", argumentsJSON: "{\"question\":\"A?\"}")])])
        let b = session("sub-b", [.toolCalls([.init(id: "c2", name: "ask_user", argumentsJSON: "{\"question\":\"B?\"}")])])
        _ = await orch.spawn(id: "sub-a", objective: "把待办同步到 Notion", session: a)
        _ = await orch.spawn(id: "sub-b", objective: "把待办同步到 Notion", session: b)

        // 两条都卡在等用户 → 槽位已释放,runningCount=0(修死锁:不再被"等你补充"占满)。
        let running = await orch.runningCount()
        XCTAssertEqual(running, 0, "卡住等用户的任务不占并发槽")
        let blocked = await orch.blockedIDs()
        XCTAssertEqual(Set(blocked), ["sub-a", "sub-b"], "两条仍在账本里记为卡住(会话保留,可续接)")

        // 槽位释放 → 新任务能派出去(旧逻辑会因满槽返回 false=死锁)。
        let c = session("sub-c", [.text("C 完成")])
        let admitted = await orch.spawnDetached(id: "sub-c", objective: "另一件事", session: c)
        XCTAssertTrue(admitted, "卡住任务释放槽后新任务应能派出,不被死锁卡住")
    }

    // 设计点①(隔离):两条子会话各自独立,账本分别记录,互不污染。
    func testTwoSubsAreIsolatedInLedger() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        let a = session("sub-a", [.text("A 的结果")])
        let b = session("sub-b", [.text("B 的结果")])
        _ = await orch.spawn(id: "sub-a", objective: "任务A", session: a)
        _ = await orch.spawn(id: "sub-b", objective: "任务B", session: b)

        let ledger = await orch.ledger()
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(ledger.first { $0.id == "sub-a" }?.summary, "A 的结果")
        XCTAssertEqual(ledger.first { $0.id == "sub-b" }?.summary, "B 的结果")
        XCTAssertTrue(ledger.allSatisfy { $0.status == .completed })
    }

    // 设计点③(消歧):多个卡住时不瞎路由,返回 nil 交主会话确认。
    func testAmbiguousFollowupReturnsNil() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        let a = session("sub-a", [.toolCalls([.init(id: "c1", name: "ask_user", argumentsJSON: "{\"question\":\"A问\"}")])])
        let b = session("sub-b", [.toolCalls([.init(id: "c2", name: "ask_user", argumentsJSON: "{\"question\":\"B问\"}")])])
        _ = await orch.spawn(id: "sub-a", objective: "任务A", session: a)
        _ = await orch.spawn(id: "sub-b", objective: "任务B", session: b)

        let blocked = await orch.blockedIDs()
        XCTAssertEqual(Set(blocked), ["sub-a", "sub-b"])
        let routed = await orch.routeFollowup("某个答案")
        XCTAssertNil(routed, "两个都卡住时不应擅自路由")
    }
}
