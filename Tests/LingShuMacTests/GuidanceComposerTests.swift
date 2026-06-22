import XCTest
@testable import LingShuMac

/// 通用中枢 P6+·**编译核心变体**(协议变体 + 特性开关)纯测:组合器实现键解析 + 两个编译变体的组合语义。
final class GuidanceComposerTests: XCTestCase {

    func testAppendIsDefaultAndPutsStrategyLast() {
        let c = LingShuGuidanceComposers.resolve(nil)
        XCTAssertEqual(type(of: c).key, "append", "未知/空键 → 默认 append(基线)")
        let out = c.compose(experience: "EXP", strategy: "STRAT")
        XCTAssertEqual(out, "EXP\n\nSTRAT", "append:经验在前、策略后置")
    }

    func testPrependPutsStrategyFirst() {
        let c = LingShuGuidanceComposers.resolve("prepend")
        XCTAssertEqual(type(of: c).key, "prepend")
        let out = c.compose(experience: "EXP", strategy: "STRAT")
        XCTAssertEqual(out, "STRAT\n\nEXP", "prepend:策略前置、经验随后")
    }

    func testOrderActuallyDiffersBetweenVariants() {
        let a = LingShuGuidanceComposers.resolve("append").compose(experience: "E", strategy: "S")
        let p = LingShuGuidanceComposers.resolve("prepend").compose(experience: "E", strategy: "S")
        XCTAssertNotEqual(a, p, "两个编译变体对同一输入产出不同顺序(切换有真实可观察差异)")
        XCTAssertTrue(a.hasPrefix("E"))
        XCTAssertTrue(p.hasPrefix("S"))
    }

    func testEmptyInputsHandledGracefully() {
        let c = LingShuGuidanceComposers.resolve("append")
        XCTAssertEqual(c.compose(experience: "EXP", strategy: ""), "EXP", "策略空 → 只返回经验(行为同历史)")
        XCTAssertEqual(c.compose(experience: "", strategy: "STRAT"), "STRAT", "经验空 → 只返回策略")
        XCTAssertEqual(c.compose(experience: "  ", strategy: "  "), "", "都空 → 空")
        // prepend 同样优雅
        XCTAssertEqual(LingShuGuidanceComposers.resolve("prepend").compose(experience: "EXP", strategy: ""), "EXP")
    }

    func testUnknownKeyFallsBackToAppend() {
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve("nope")).key, "append")
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve("")).key, "append")
    }

    func testAvailableKeysListsAllCompiledVariants() {
        XCTAssertEqual(Set(LingShuGuidanceComposers.availableKeys), ["append", "prepend"])
    }
}
