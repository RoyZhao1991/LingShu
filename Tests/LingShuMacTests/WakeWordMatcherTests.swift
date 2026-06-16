import XCTest
@testable import LingShuMac

/// 唤醒词宽松匹配（同音近音）+ 指令剥离。修复 bug #4「喊灵枢唤不醒」=ASR 把"灵枢"转写不稳。
final class WakeWordMatcherTests: XCTestCase {
    private let wake = "灵枢"

    func testExactMatch() {
        XCTAssertTrue(LingShuWakeWordMatcher.contains("灵枢介绍一下你自己", wakeWord: wake))
    }

    func testMatchIgnoresWhitespaceAndPunctuation() {
        XCTAssertTrue(LingShuWakeWordMatcher.contains("灵枢，你好", wakeWord: wake))
        XCTAssertTrue(LingShuWakeWordMatcher.contains("灵 枢 在 吗", wakeWord: wake))
        XCTAssertTrue(LingShuWakeWordMatcher.contains("Hi，灵枢！", wakeWord: wake))
    }

    func testHomophoneVariantsMatch() {
        // ASR 常见误转写都应能唤醒（宁可宽一点）。
        for variant in ["灵书帮我看下", "铃枢在吗", "凌枢过来", "灵树你听得到吗", "灵数介绍下自己"] {
            XCTAssertTrue(LingShuWakeWordMatcher.contains(variant, wakeWord: wake), "应命中变体：\(variant)")
        }
    }

    func testUnrelatedTextDoesNotMatch() {
        XCTAssertFalse(LingShuWakeWordMatcher.contains("今天天气不错", wakeWord: wake))
        XCTAssertFalse(LingShuWakeWordMatcher.contains("帮我打开文件", wakeWord: wake))
    }

    func testCustomWakeWordAlsoMatches() {
        XCTAssertTrue(LingShuWakeWordMatcher.contains("小灵小灵在吗", wakeWord: "小灵"))
        // 自定义词不命中时仍可走内建灵枢变体。
        XCTAssertTrue(LingShuWakeWordMatcher.contains("灵枢在吗", wakeWord: "小灵"))
    }

    func testStripWakeWordReturnsCommandBody() {
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "灵枢，介绍一下你自己", wakeWord: wake), "介绍一下你自己")
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "铃枢 帮我做个PPT", wakeWord: wake), "帮我做个PPT")
    }

    func testStripKeepsTextWhenNoWakeWord() {
        // 已在对话态、整句都是指令：原样返回。
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "介绍一下你自己", wakeWord: wake), "介绍一下你自己")
    }

    func testStripKeepsGreetingWhenOnlyWakeWord() {
        // 只喊了名字、没带指令 → 不返回空串（当成招呼，保留原文）。
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "灵枢", wakeWord: wake), "灵枢")
        XCTAssertEqual(LingShuWakeWordMatcher.stripWakeWord(from: "灵枢！", wakeWord: wake), "灵枢！")
    }
}
