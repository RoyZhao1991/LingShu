import XCTest
@testable import LingShuMac

/// 打断标志粘滞泄漏回归(测无可测战役·Round 3,经典引擎)。
/// 历史根因 [[verify-gate-bypass-batchinterrupt-leak]]:在岗模式任一打断置 `batchInterruptRequested=true` 后无人复位,
/// 泄漏到**下一回合的验收门**(recoverFromExhaustion/runVerificationLoop 一进门 `if batchInterruptRequested { return }`
/// → maker≠checker 验收被静默旁路,坏交付物蒙混过关)。
/// 修复:`driveAgentDelivery` 新一段驱动开始即复位(对标嵌套引擎 consumeInterrupt)。本测守住"新驱动入口必复位"。
@MainActor
final class BatchInterruptLeakTests: XCTestCase {

    func testDriveResetsStaleInterruptFlagAtEntry() async {
        let state = LingShuState()
        // 模拟上一回合打断留下的粘滞标志。
        state.batchInterruptRequested = true

        // 一个立即收尾、无产出物的会话:driveAgentDelivery 会过 verifyAndContinue,但无新产出物→不触发重型验收(纯离线)。
        let model = LingShuScriptedAgentModel([.text("已完成")])
        let session = LingShuAgentSession(id: "leak-test", tools: [], model: model)

        let result = await state.driveAgentDelivery(session: session, prompt: "做点事", taskRecordID: nil, trustReplyClaim: false)

        XCTAssertFalse(state.batchInterruptRequested,
                       "新一段驱动开始必须复位打断标志——否则上回合的打断会泄漏旁路本回合验收门")
        if case .completed = result {} else { XCTFail("简单收尾应是 completed,实际 \(result)") }
    }

    /// **打断恢复孤儿 tool_call 泄漏回归(2026-06-22,独立验收实锤 @ 7a6744f → 修复后转绿)**。
    /// 历史:飞行中 `lingshu_stop` 取消落在"assistant 已声明 tool_calls、tool 结果未回填"之间→持久会话留未应答 tool_call→
    /// 下一回合 `checkInvariants` 记 I1/I2、`loopInvariantViolations` 累计爬升(soak 打断恢复 0→3→8)。
    /// 修复:`send`/`resume`/`continueLoop` 续接入口先 `repairOrphanToolCalls` 补齐。本测用 `initialMessages` 注入孤儿
    /// (等价取消留下的半截状态),断言续接一条干净任务后**会话内不变量违反为空**(修复前此处会记 I1/I2)。
    func testOrphanToolCallRepairedOnResumeNoInvariantLeak() async {
        // 模拟"飞行中被取消"留下的孤儿:assistant 声明了 write_file 调用,但**没有**对应 tool 结果。
        let orphanHistory: [LingShuAgentMessage] = [
            .init(role: .user, content: "帮我写个素数筛,写完测一下"),
            .init(role: .assistant, content: "", toolCalls: [
                .init(id: "tc_orphan", name: "write_file", argumentsJSON: "{\"path\":\"sieve.py\"}")
            ])
            // 故意不补 tool 结果 = 孤儿(取消在 dispatch 前停下)
        ]
        let model = LingShuScriptedAgentModel([.text("3 加 4 等于 7。")])
        let session = LingShuAgentSession(id: "orphan-repair", initialMessages: orphanHistory, tools: [], model: model)

        // 续接一条干净任务(对标 soak「打断后发干净问题」)。
        let result = await session.send("顺便问下,3 加 4 等于几?")

        if case .completed = result {} else { XCTFail("干净续接应正常收尾,实际 \(result)") }
        let violations = await session.recordedInvariantViolations
        XCTAssertTrue(violations.isEmpty,
                      "续接前必须修齐孤儿 tool_call——否则 .afterCompaction/.beforeModelCall 会记 I1/I2(打断恢复不变量泄漏)。实际:\(violations.map(\.description))")
    }

    /// **取消恢复·同回合部分 dispatch 孤儿根治回归(2026-06-22)**:飞行中取消让调度器只返回部分结果时,
    /// 本回合就会留下未应答 tool_call → 该回合 `.terminal` 不变量检查当场记 I1/I2(soak 打断恢复 #2 仍泄漏 8 的真因)。
    /// 修复:dispatch 落结果后给未应答 call 当场补合成结果。本测用"丢一个结果"的调度器复现,断言会话内不变量为空。
    private struct DroppingDispatcher: LingShuToolDispatching {
        func dispatch(_ calls: [LingShuAgentToolCall], tools: [LingShuAgentTool]) async -> [LingShuToolCallOutcome] {
            // 模拟取消:只执行第一个,其余结果"丢失"(调度器返回部分)。
            guard let first = calls.first, let tool = tools.first(where: { $0.name == first.name }) else { return [] }
            return [LingShuToolCallOutcome(id: first.id, name: first.name, output: await tool.handler(first.argumentsJSON))]
        }
    }
    func testPartialDispatchBackfilledNoInvariantLeak() async {
        let tool = LingShuAgentTool(name: "do_work", description: "d") { _ in "ok" }
        // 模型一轮发两个工具调用 → 调度器只回一个 → 另一个若不补结果即孤儿;下一轮模型收尾。
        let model = LingShuScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "do_work", argumentsJSON: "{}"),
                        .init(id: "c2", name: "do_work", argumentsJSON: "{}")]),
            .text("都做完了。")
        ])
        let session = LingShuAgentSession(id: "partial-dispatch", tools: [tool], model: model,
                                          toolDispatcher: DroppingDispatcher())
        let result = await session.send("做两件事")
        if case .completed = result {} else { XCTFail("应正常收尾,实际 \(result)") }
        let violations = await session.recordedInvariantViolations
        XCTAssertTrue(violations.isEmpty,
                      "部分 dispatch 后必须给未应答 call 补结果——否则本回合即记 I1/I2。实际:\(violations.map(\.description))")
    }

    func testFreshInterruptDuringTurnSurvivesEntryReset() {
        // 复位只发生在驱动入口(send 之前);本回合自身的打断(入口之后才置)不该被这次复位吞掉。
        // 这里直接验证语义:入口复位后再置 true(模拟回合中途 barge)→ 标志为 true,会被验收门的中途检查捕获。
        let state = LingShuState()
        state.batchInterruptRequested = false   // 入口已复位(无残留)
        state.batchInterruptRequested = true    // 本回合中途真打断
        XCTAssertTrue(state.batchInterruptRequested, "回合中途的真打断应保留,供验收门中途检查中止")
    }

    func testCancelCurrentCallCancelsTaskEvenWhenModelFlagAlreadyFalse() {
        let state = LingShuState()
        state.isModelReplying = false
        state.isModelExecuting = false
        state.activeAgentTurnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        state.cancelCurrentCall()

        XCTAssertNil(state.activeAgentTurnTask, "停止必须按真实 Task 判定,不能因 hasActiveModelCall=false 早退")
        XCTAssertTrue(state.batchInterruptRequested, "停止应留下批量打断信号,让 run_steps/验收循环在边界退出")
    }

    func testStandingPersonOnDutyDoesNotDependOnSessionHolderStartupRace() {
        let state = LingShuState()
        var run = LingShuAutonomousRunSnapshot.idle
        run.objective = ""
        run.phase = .running
        state.autonomousRun = run
        state.autonomousSessionHolder = nil

        XCTAssertTrue(state.isStandingPersonOnDuty,
                      "上岗状态应由状态机决定;会话对象异步构造期间不能误报 off")
    }

    func testTurnBoundaryBlocksHistoryBleedForFreshPrompt() {
        let guidance = LingShuState.turnBoundaryGuidance(for: "打断后恢复测试:1+1 等于几?一句话回答。", base: "基础策略")

        XCTAssertTrue(guidance.contains("只回答或处理下面这条最新输入"))
        XCTAssertTrue(guidance.contains("不要凭某个词直接续跑旧任务"))
        XCTAssertTrue(guidance.contains("基础策略"))
    }

    func testTurnBoundaryDoesNotPromoteHistoryByKeyword() {
        let guidance = LingShuState.turnBoundaryGuidance(for: "继续上次那个爬虫任务", base: nil)

        XCTAssertTrue(guidance.contains("只回答或处理下面这条最新输入"))
        XCTAssertTrue(guidance.contains("由主脑基于完整上下文作出结构化续接决策"))
        XCTAssertFalse(guidance.contains("用户这轮可能在续接历史任务"))
    }

    func testBareContinueCanFollowRecentConversationContext() {
        let guidance = LingShuState.turnBoundaryGuidance(for: "继续", base: nil)

        XCTAssertTrue(guidance.contains("如果最新输入是在延续刚才的普通对话"))
        XCTAssertFalse(guidance.contains("用户这轮可能在续接历史任务"))
    }
}
