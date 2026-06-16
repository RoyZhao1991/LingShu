import XCTest
@testable import LingShuMac

/// 唤醒词**读音**匹配（拼音 + 模糊音）。bug #4：生僻词"灵枢"ASR 几乎转写不对，靠读音才唤得醒。
final class WakeWordMatcherTests: XCTestCase {
    private let wake = "灵枢"

    func testExactAndPunctuation() {
        XCTAssertTrue(LingShuWakeWordMatcher.contains("灵枢介绍一下你自己", wakeWord: wake))
        XCTAssertTrue(LingShuWakeWordMatcher.contains("灵枢，你好", wakeWord: wake))
        XCTAssertTrue(LingShuWakeWordMatcher.contains("Hi，灵枢！在吗", wakeWord: wake))
    }

    func testHomophonesMatchByPinyin() {
        // ASR 把"灵枢"写成各种同音字——读音一致就该命中（不靠我手工穷举）。
        for variant in ["灵书帮我看下", "铃枢在吗", "凌书过来", "灵树你听得到吗",
                        "灵舒介绍下自己", "另书帮个忙", "铃树在不在"] {
            XCTAssertTrue(LingShuWakeWordMatcher.contains(variant, wakeWord: wake), "应按读音命中：\(variant)")
        }
    }

    func testFuzzySoundsMatch() {
        // 模糊音:l↔n、-ng↔-n、sh↔s。南方口音/ASR 混淆也要接住。
        XCTAssertEqual(LingShuWakeWordMatcher.fuzzyKey("ling"), LingShuWakeWordMatcher.fuzzyKey("lin"))
        XCTAssertEqual(LingShuWakeWordMatcher.fuzzyKey("ning"), LingShuWakeWordMatcher.fuzzyKey("ling"))
        XCTAssertEqual(LingShuWakeWordMatcher.fuzzyKey("shu"), LingShuWakeWordMatcher.fuzzyKey("su"))
        XCTAssertEqual(LingShuWakeWordMatcher.fuzzyKey("zhu"), LingShuWakeWordMatcher.fuzzyKey("zu"))
        // "您输"(nin shu) 读音接近 灵枢 → 命中（用户要的就是高敏感）。
        XCTAssertTrue(LingShuWakeWordMatcher.contains("您输一下", wakeWord: wake))
    }

    func testUnrelatedDoesNotMatch() {
        for t in ["今天天气不错", "帮我打开文件", "玲珑塔有几层", "你好世界", "灵感来了写代码"] {
            XCTAssertFalse(LingShuWakeWordMatcher.contains(t, wakeWord: wake), "不该误命中：\(t)")
        }
    }

    func testCustomWakeWordMatchesByPinyin() {
        // 自定义唤醒词也走读音匹配:"小爱"→ ASR 写成"小艾/晓爱"都该命中。
        XCTAssertTrue(LingShuWakeWordMatcher.contains("小艾帮我查下", wakeWord: "小爱"))
        XCTAssertTrue(LingShuWakeWordMatcher.contains("晓爱在吗", wakeWord: "小爱"))
        // 内建灵枢变体始终兜底。
        XCTAssertTrue(LingShuWakeWordMatcher.contains("灵枢在吗", wakeWord: "小爱"))
    }

    func testStripWakeWordByLiteralAndPinyin() {
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "灵枢，介绍一下你自己", wakeWord: wake), "介绍一下你自己")
        // 读音剥离:句首同音字也要剥掉。
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "灵书 帮我做个PPT", wakeWord: wake), "帮我做个PPT")
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "另书，现在几点", wakeWord: wake), "现在几点")
    }

    func testStripKeepsTextWhenNoWakeWordOrOnlyGreeting() {
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "介绍一下你自己", wakeWord: wake), "介绍一下你自己")
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "灵枢", wakeWord: wake), "灵枢")
    }
}
