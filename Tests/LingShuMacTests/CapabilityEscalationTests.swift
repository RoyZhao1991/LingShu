import XCTest
@testable import LingShuMac

/// # 能力升级阶梯测试 —— 方案 §2 的"失败升级脚手架阶梯"纯逻辑
///
/// 给定 verify 结果序列,断言升级路径:默认从最薄 Rung0 起,verify 不过才升级;过即停;askUser 提前交还。
final class CapabilityEscalationTests: XCTestCase {

    /// 构造一个按 rung 返回预设 verify 结果的编排,跑完拿 Outcome。
    private func run(verifyByRung: [Bool],
                     askUserAtRung: Int? = nil) async -> LingShuCapabilityEscalation.Outcome<Int> {
        let rungs = ["", "结构化引导", "确定性兜底"]   // Rung0 最薄 → Rung1 引导 → Rung2 兜底
        return await LingShuCapabilityEscalation.run(
            goal: "把灯接入",
            rungs: rungs,
            attempt: { rung, _, _ in rung },          // 结果就携带它在哪一级跑的
            verify: { rung, _ in verifyByRung[rung] },
            triggerOf: { rung, _ in rung == askUserAtRung ? .askedUser : nil })
    }

    // MARK: - 默认从 Rung0 起,过即停(强脑路径)

    func testPassesAtRung0WithoutEscalating() async {
        let o = await run(verifyByRung: [true, true, true])
        XCTAssertTrue(o.succeeded)
        XCTAssertEqual(o.rungReached, 0, "Rung0 就过,绝不无谓升级")
        XCTAssertEqual(o.trace, ["rung0:attempt", "rung0:pass"])
    }

    // MARK: - 失败逐级升级,最终在 Rung2 过(弱脑路径)

    func testEscalatesUntilVerifyPasses() async {
        let o = await run(verifyByRung: [false, false, true])
        XCTAssertTrue(o.succeeded)
        XCTAssertEqual(o.rungReached, 2, "Rung0/1 都不过 → 升到 Rung2 才过")
        XCTAssertEqual(o.trace, ["rung0:attempt", "rung0:fail",
                                 "rung1:attempt", "rung1:fail",
                                 "rung2:attempt", "rung2:pass"])
    }

    func testEscalatesToRung1() async {
        let o = await run(verifyByRung: [false, true, true])
        XCTAssertTrue(o.succeeded)
        XCTAssertEqual(o.rungReached, 1)
    }

    // MARK: - 升到顶仍不过 → 诚实交还(不假装完成)

    func testExhaustsAllRungsAndHandsBack() async {
        let o = await run(verifyByRung: [false, false, false])
        XCTAssertFalse(o.succeeded, "全程不过不能算成功(根治'声称完成')")
        XCTAssertFalse(o.handback, "这是升到顶仍失败,不是 askUser 提前交还")
        XCTAssertEqual(o.rungReached, 2)
        XCTAssertEqual(o.trace.last, "rung2:fail")
    }

    // MARK: - askUser 自述缺信息 → 立刻交还,不再升级(加脚手架补不了用户信息)

    func testAskUserStopsEscalationImmediately() async {
        let o = await run(verifyByRung: [false, false, false], askUserAtRung: 0)
        XCTAssertFalse(o.succeeded)
        XCTAssertTrue(o.handback, "askUser=诚实交还")
        XCTAssertEqual(o.rungReached, 0, "在 Rung0 就交还,不浪费升级")
        XCTAssertEqual(o.trace, ["rung0:attempt", "rung0:handback(askedUser)"])
    }
}
