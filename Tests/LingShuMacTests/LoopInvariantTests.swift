import XCTest
@testable import LingShuMac

/// 循环不变量纯逻辑守卫(差距1·架网):直接喂构造好的"坏状态"给纯检查器,断言它**抓得到**;
/// 喂良构状态断言它**不误报**。这是"网"的最内层——检查器本身正确,fuzz/soak 才有意义。
final class LoopInvariantTests: XCTestCase {

    private func msg(_ role: LingShuAgentRole, _ content: String = "", calls: [LingShuAgentToolCall] = [], toolCallID: String? = nil) -> LingShuAgentMessage {
        LingShuAgentMessage(role: role, content: content, toolCalls: calls, toolCallID: toolCallID)
    }
    private func call(_ id: String, _ name: String = "t") -> LingShuAgentToolCall {
        LingShuAgentToolCall(id: id, name: name, argumentsJSON: "{}")
    }

    // MARK: 良构序列不误报

    func testWellFormedSequenceHasNoViolations() {
        let messages = [
            msg(.system, "身份"),
            msg(.user, "做点事"),
            msg(.assistant, calls: [call("c1")]),
            msg(.tool, "结果1", toolCallID: "c1"),
            msg(.assistant, "完成"),
        ]
        let s = LingShuLoopStateSnapshot(messages: messages)
        XCTAssertTrue(LingShuLoopInvariants.check(s, at: .beforeModelCall).isEmpty)
        XCTAssertTrue(LingShuLoopInvariants.check(s, at: .terminal(.completed)).isEmpty)
    }

    func testMultiCallTurnAllAnsweredIsWellFormed() {
        let messages = [
            msg(.assistant, calls: [call("a"), call("b")]),
            msg(.tool, "ra", toolCallID: "a"),
            msg(.tool, "rb", toolCallID: "b"),
            msg(.user, "再来"),
        ]
        XCTAssertTrue(LingShuLoopInvariants.check(.init(messages: messages), at: .beforeModelCall).isEmpty)
    }

    // MARK: I1 孤儿 / 缺 ID

    func testOrphanToolResultCaught() {
        let messages = [msg(.user, "x"), msg(.tool, "结果", toolCallID: "ghost")]
        let v = LingShuLoopInvariants.check(.init(messages: messages), at: .beforeModelCall)
        XCTAssertTrue(v.contains(.orphanToolResult(toolCallID: "ghost")), "孤儿 tool 结果应被抓到:\(v)")
    }

    func testToolResultMissingIDCaught() {
        let messages = [msg(.assistant, calls: [call("c1")]), msg(.tool, "结果", toolCallID: nil)]
        let v = LingShuLoopInvariants.check(.init(messages: messages), at: .beforeModelCall)
        XCTAssertTrue(v.contains { if case .toolResultMissingID = $0 { return true }; return false }, "缺 toolCallID 应被抓到:\(v)")
    }

    // MARK: I2 未应答的 tool_call(网关 400 的高频根因)

    func testUnansweredToolCallBeforeUserMessageCaught() {
        // assistant 发起 tool_call 后,没补结果就来了 user 消息 → 不良构。
        let messages = [msg(.assistant, calls: [call("c1")]), msg(.user, "插话")]
        let v = LingShuLoopInvariants.check(.init(messages: messages), at: .beforeModelCall)
        XCTAssertTrue(v.contains(.unansweredToolCall(toolCallID: "c1")), "未应答 tool_call 应被抓到:\(v)")
    }

    func testPartiallyAnsweredMultiCallCaught() {
        // 同回合两个调用,只应答了一个 → 另一个未应答。
        let messages = [
            msg(.assistant, calls: [call("a"), call("b")]),
            msg(.tool, "ra", toolCallID: "a"),
            msg(.assistant, "我以为做完了"),
        ]
        let v = LingShuLoopInvariants.check(.init(messages: messages), at: .terminal(.completed))
        XCTAssertTrue(v.contains(.unansweredToolCall(toolCallID: "b")), "未应答的 b 应被抓到:\(v)")
        XCTAssertFalse(v.contains(.unansweredToolCall(toolCallID: "a")), "已应答的 a 不该报")
    }

    func testBlockedTerminalAllowsPendingOpenCall() {
        // .blocked 终态:阻塞那条调用 open 是合法的(等 resume 回填),不该报未应答。
        let messages = [msg(.user, "?"), msg(.assistant, calls: [call("ask", "ask_user")])]
        let s = LingShuLoopStateSnapshot(messages: messages, pendingBlockToolCallID: "ask")
        let v = LingShuLoopInvariants.check(s, at: .terminal(.blocked))
        XCTAssertTrue(v.isEmpty, "阻塞 pending 调用不该被当未应答:\(v)")
    }

    func testBlockedTerminalStillCatchesOtherUnansweredCall() {
        // .blocked 时若同回合还有别的非阻塞调用没补结果 → 仍是孤儿(豁免只给 pending 那条)。
        let messages = [msg(.assistant, calls: [call("other"), call("ask", "ask_user")])]
        let s = LingShuLoopStateSnapshot(messages: messages, pendingBlockToolCallID: "ask")
        let v = LingShuLoopInvariants.check(s, at: .terminal(.blocked))
        XCTAssertTrue(v.contains(.unansweredToolCall(toolCallID: "other")), "非阻塞的 other 仍应报未应答:\(v)")
    }

    // MARK: I3/I4 标志一致性 —— 故意注入粘滞标志,断言抓得到(方案验收要求)

    func testStickyBlockFlagLeakCaught() {
        // 故意:结果是 .completed 却残留 pendingBlockToolCallID(阻塞标志粘滞泄漏)→ 必须抓到。
        let s = LingShuLoopStateSnapshot(messages: [msg(.assistant, "done")], pendingBlockToolCallID: "stuck-block")
        let v = LingShuLoopInvariants.check(s, at: .terminal(.completed))
        XCTAssertTrue(v.contains(.blockStateInconsistent(pendingNil: false, kind: .completed)), "粘滞阻塞标志应被抓到:\(v)")
    }

    func testBlockedWithoutPendingCaught() {
        // 反向:结果是 .blocked 却没有 pending → 也不一致。
        let s = LingShuLoopStateSnapshot(messages: [msg(.assistant, "?")], pendingBlockToolCallID: nil)
        let v = LingShuLoopInvariants.check(s, at: .terminal(.blocked))
        XCTAssertTrue(v.contains(.blockStateInconsistent(pendingNil: true, kind: .blocked)), "阻塞却无 pending 应被抓到:\(v)")
    }

    func testRunningAfterTerminalCaught() {
        let s = LingShuLoopStateSnapshot(messages: [msg(.assistant, "done")], isRunning: true)
        let v = LingShuLoopInvariants.check(s, at: .terminal(.completed))
        XCTAssertTrue(v.contains(.runningAfterTerminal), "终态后仍 running 应被抓到:\(v)")
    }

    // MARK: I5 纠正未采纳即收尾

    func testCorrectionNotConsumedAtCompletionCaught() {
        let s = LingShuLoopStateSnapshot(messages: [msg(.assistant, "done")], hasPendingCorrection: true)
        let v = LingShuLoopInvariants.check(s, at: .terminal(.completed))
        XCTAssertTrue(v.contains(.correctionNotConsumed(kind: .completed)), "完成时残留纠正应被抓到:\(v)")
    }

    // MARK: I6 历史预算

    func testHistoryOverBudgetCaught() {
        var messages = [msg(.system, "身份")]
        for i in 0..<20 { messages.append(msg(.user, "第\(i)轮")) }   // body=20,窗口=4 → 超
        let s = LingShuLoopStateSnapshot(messages: messages, maxHistoryMessages: 4)
        let v = LingShuLoopInvariants.check(s, at: .afterCompaction)
        XCTAssertTrue(v.contains { if case .historyOverBudget = $0 { return true }; return false }, "历史超预算应被抓到:\(v)")
    }

    func testHistoryWithinBudgetNoViolation() {
        let messages = [msg(.system, "身份"), msg(.user, "a"), msg(.assistant, "b"), msg(.user, "c")]
        let s = LingShuLoopStateSnapshot(messages: messages, maxHistoryMessages: 4)
        XCTAssertTrue(LingShuLoopInvariants.check(s, at: .afterCompaction).isEmpty)
    }

    func testUnboundedHistoryNeverOverBudget() {
        // maxHistoryMessages=0(不裁剪的短命子会话)→ 预算不适用,绝不报。
        var messages: [LingShuAgentMessage] = []
        for i in 0..<50 { messages.append(msg(.user, "第\(i)")) }
        let s = LingShuLoopStateSnapshot(messages: messages, maxHistoryMessages: 0)
        XCTAssertTrue(LingShuLoopInvariants.checkHistoryBudget(messages: messages, maxHistoryMessages: 0).isEmpty)
        XCTAssertTrue(LingShuLoopInvariants.check(s, at: .afterCompaction).isEmpty)
    }

    // MARK: I6 token 预算模式(差距4 分层压缩契约)

    func testTokenBudgetModeIgnoresMessageCount() {
        // token 压缩契约下:很多条小消息(条数远超任何窗口)但总 token 在预算内 → 绝不按条数误报。
        var messages = [msg(.system, "身份")]
        for i in 0..<40 { messages.append(msg(.user, "短\(i)")) }   // 40 条但 token 很少
        let s = LingShuLoopStateSnapshot(messages: messages, maxHistoryMessages: 4, compactionBudget: .tokens(10_000))
        XCTAssertTrue(LingShuLoopInvariants.check(s, at: .afterCompaction).isEmpty, "token 模式不该按条数报超预算")
    }

    func testTokenBudgetModeCatchesUnboundedGrowth() {
        // 压缩没跑→很多条中等消息堆出远超预算的总 token → 应抓到(token 超预算)。
        var messages = [msg(.system, "身份")]
        let chunk = String(repeating: "压缩没跑就会无界累积", count: 30)   // 每条 ~300 token
        for _ in 0..<20 { messages.append(msg(.user, chunk)) }              // ~6000 token,预算 1000
        let s = LingShuLoopStateSnapshot(messages: messages, maxHistoryMessages: 0, compactionBudget: .tokens(1_000))
        let v = LingShuLoopInvariants.check(s, at: .afterCompaction)
        XCTAssertTrue(v.contains { if case .historyTokensOverBudget = $0 { return true }; return false }, "token 无界增长应被抓到:\(v)")
    }

    func testTokenBudgetModeExemptsSingleHugeMessage() {
        // 单条巨型消息(用户贴超长文本)无法再切 → 豁免,不误报。
        let huge = String(repeating: "这是一段非常长的粘贴内容无法被压缩器再切分", count: 200)  // 单条远超预算
        let messages = [msg(.system, "身份"), msg(.user, "正常一句"), msg(.user, huge)]
        let s = LingShuLoopStateSnapshot(messages: messages, maxHistoryMessages: 0, compactionBudget: .tokens(1_000))
        XCTAssertTrue(LingShuLoopInvariants.check(s, at: .afterCompaction).isEmpty, "单条巨型消息应被豁免,不误报")
    }

    // MARK: 遥测累计

    func testTelemetryAccumulatesAndResets() {
        LingShuLoopInvariantTelemetry.reset()
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0)
        LingShuLoopInvariantTelemetry.record([.runningAfterTerminal, .orphanToolResult(toolCallID: "x")], boundary: .beforeModelCall)
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 2)
        XCTAssertFalse(LingShuLoopInvariantTelemetry.lastSamples.isEmpty)
        LingShuLoopInvariantTelemetry.reset()
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0)
        XCTAssertTrue(LingShuLoopInvariantTelemetry.lastSamples.isEmpty)
    }
}
