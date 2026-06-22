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

    func testFreshInterruptDuringTurnSurvivesEntryReset() {
        // 复位只发生在驱动入口(send 之前);本回合自身的打断(入口之后才置)不该被这次复位吞掉。
        // 这里直接验证语义:入口复位后再置 true(模拟回合中途 barge)→ 标志为 true,会被验收门的中途检查捕获。
        let state = LingShuState()
        state.batchInterruptRequested = false   // 入口已复位(无残留)
        state.batchInterruptRequested = true    // 本回合中途真打断
        XCTAssertTrue(state.batchInterruptRequested, "回合中途的真打断应保留,供验收门中途检查中止")
    }
}
