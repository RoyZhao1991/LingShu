import XCTest
@testable import LingShuMac

/// 差距2·薄基线:脑力分→连续起步档的纯逻辑守卫。
/// 核心断言:**无 85 二元硬跳变**(一道偏题不把强脑打回厚)、分级连续、安全红线各档恒在。
final class HarnessProfileTests: XCTestCase {

    func testStrongBrainStartsLean() {
        let cap = LingShuHarnessProfile.capability(benchmark: 93, runNetScore: 4)
        XCTAssertEqual(LingShuHarnessProfile.tier(cap), .lean)
    }

    func testWeakBrainStartsGuided() {
        let cap = LingShuHarnessProfile.capability(benchmark: 30, runNetScore: -2)
        XCTAssertEqual(LingShuHarnessProfile.tier(cap), .guided)
    }

    func testSingleOffQuestionDoesNotFlipStrongBrainToThick() {
        // 关键:98 分因一道字符级偏题跌到 88 → 仍是 lean(旧二元 85 阈值会在 84 翻车;这里阈值 75 带间隔,不翻)。
        let high = LingShuHarnessProfile.capability(benchmark: 98, runNetScore: 0)
        let dipped = LingShuHarnessProfile.capability(benchmark: 88, runNetScore: 0)
        XCTAssertEqual(LingShuHarnessProfile.tier(high), .lean)
        XCTAssertEqual(LingShuHarnessProfile.tier(dipped), .lean, "强脑一道偏题(98→88)不该被打回厚档")
    }

    func testTierIsMonotonicInCapability() {
        // 连续性:能力越高档越薄(lean<balanced<guided 的反向),不出现非单调跳变。
        func rank(_ t: LingShuHarnessProfile.Tier) -> Int { switch t { case .guided: return 0; case .balanced: return 1; case .lean: return 2 } }
        var lastRank = -1
        for score in stride(from: 0, through: 100, by: 1) {
            let r = rank(LingShuHarnessProfile.tier(Double(score)))
            XCTAssertGreaterThanOrEqual(r, lastRank, "档位应随能力分单调不降(无来回跳变),score=\(score)")
            lastRank = r
        }
    }

    func testBenchmarkDominatesOverRunScore() {
        // 运行净分被有界微调,基准主导:高基准 + 极差运行净分仍偏薄(不被单次兜底打到厚档)。
        let cap = LingShuHarnessProfile.capability(benchmark: 90, runNetScore: -100)
        XCTAssertGreaterThanOrEqual(cap, 75, "基准 90 应主导,运行净分只能微调,不至于跌出 lean")
    }

    func testSafetyLineInEveryTier() {
        for cap in [10.0, 60.0, 95.0] {
            let prefix = LingShuHarnessProfile.knobPrefix(capability: cap, tag: "t")
            XCTAssertTrue(prefix.contains("安全红线"), "每一档起步提示都必须含安全红线(cap=\(cap))")
        }
    }

    func testNoBenchmarkFallsBackToRunScore() {
        // 无基准时运行净分驱动能力分(差脑起步引导、好运行记录起步更薄);需很强运行记录才到 lean。
        let lo = LingShuHarnessProfile.capability(benchmark: nil, runNetScore: -20)
        let hi = LingShuHarnessProfile.capability(benchmark: nil, runNetScore: 20)
        XCTAssertLessThan(lo, hi, "运行净分应驱动能力分(无基准兜底)")
        XCTAssertEqual(LingShuHarnessProfile.tier(lo), .guided, "差运行记录起步带引导")
        XCTAssertEqual(LingShuHarnessProfile.tier(LingShuHarnessProfile.capability(benchmark: nil, runNetScore: 40)), .lean, "很强运行记录起步最薄")
    }
}
