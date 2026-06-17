import XCTest
@testable import LingShuMac

/// 自激回声判定 + 「唤醒词=触发非指令」纯逻辑测试。
final class EchoAndWakeTriggerTests: XCTestCase {

    // MARK: - 回声判定

    func testEchoDetectsOwnSpeechFragments() {
        let outputs = ["好的，请说。", "安静在岗。", "好了，我在呢。有什么任务直接说。"]
        // 截图里的真实自激回声:
        XCTAssertTrue(LingShuEchoDetector.isEcho("好的", recentOutputs: outputs))
        XCTAssertTrue(LingShuEchoDetector.isEcho("安静在岗", recentOutputs: outputs))
        XCTAssertTrue(LingShuEchoDetector.isEcho("有什么任务直接说", recentOutputs: outputs))
    }

    func testNonEchoRealInputKept() {
        let outputs = ["好的，请说。", "安静在岗。"]
        XCTAssertFalse(LingShuEchoDetector.isEcho("帮我订个会议室", recentOutputs: outputs))
        XCTAssertFalse(LingShuEchoDetector.isEcho("打开浏览器查一下天气", recentOutputs: outputs))
    }

    func testEchoEmptyOrTinyNotFlagged() {
        XCTAssertFalse(LingShuEchoDetector.isEcho("", recentOutputs: ["好的"]))
        XCTAssertFalse(LingShuEchoDetector.isEcho("好", recentOutputs: ["好的，请说"]))  // 太短不判
    }

    // MARK: - 唤醒词 = 触发,不是指令

    func testPureWakeYieldsEmptyCommand() {
        XCTAssertEqual(LingShuWakeWordMatcher.commandAfterWake(from: "灵枢", wakeWord: "灵枢"), "")
        XCTAssertEqual(LingShuWakeWordMatcher.commandAfterWake(from: "灵枢。", wakeWord: "灵枢"), "")
        XCTAssertEqual(LingShuWakeWordMatcher.commandAfterWake(from: "刘叔", wakeWord: "灵枢"), "")  // 误识别变体也算纯触发
    }

    func testWakePlusCommandYieldsCommand() {
        XCTAssertEqual(LingShuWakeWordMatcher.commandAfterWake(from: "灵枢，帮我查一下天气", wakeWord: "灵枢"), "帮我查一下天气")
        XCTAssertEqual(LingShuWakeWordMatcher.commandAfterWake(from: "灵枢 打开浏览器", wakeWord: "灵枢"), "打开浏览器")
    }
}
