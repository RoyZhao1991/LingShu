import XCTest
@testable import LingShuMac

/// # 朗读净化测试(带格式只念概要、不念格式)
final class SpokenTextTests: XCTestCase {

    func testFormattedReplyReadsLeadInSummaryNotFormat() {
        let text = "✅ 好的，你选择了接入。不过目前我手头没有客厅灯的具体设备信息，需要你提供以下信息：\n1. 客厅灯的品牌/型号是什么？\n2. 连接方式是 Wi-Fi / Zigbee / 蓝牙？\n3. 是否已有 App 或 API？\n请告诉我。"
        let s = LingShuSpokenText.concise(text)
        XCTAssertTrue(s.contains("没有客厅灯的具体设备信息"), "念前导散文概要")
        XCTAssertFalse(s.contains("1."), "不念编号")
        XCTAssertFalse(s.contains("Zigbee"), "不逐条念列表项")
        XCTAssertFalse(s.contains("✅"), "不念状态 emoji")
        XCTAssertTrue(s.contains("详情看屏幕"), "有格式内容 → 提示看屏幕")
    }

    func testPlainProseUnchanged() {
        let s = LingShuSpokenText.concise("床头灯已经打开了。")
        XCTAssertEqual(s, "床头灯已经打开了。")
        XCTAssertFalse(s.contains("详情看屏幕"))
    }

    func testStripsBoldAndCode() {
        let s = LingShuSpokenText.concise("这是**重点**内容,用 `cmd` 跑。")
        XCTAssertFalse(s.contains("**"))
        XCTAssertFalse(s.contains("`"))
        XCTAssertTrue(s.contains("重点"))
    }

    func testDropsCodeFenceBlocks() {
        let text = "我写好了脚本:\n```python\nprint('x')\n```\n可以跑了。"
        let s = LingShuSpokenText.concise(text)
        XCTAssertFalse(s.contains("print"), "代码块不念")
        XCTAssertTrue(s.contains("写好了脚本"))
    }

    func testPureListTakesFirstPointGist() {
        let s = LingShuSpokenText.concise("1. 第一项\n2. 第二项")
        XCTAssertFalse(s.contains("1."))
        XCTAssertTrue(s.contains("详情看屏幕") || s.contains("第一项"))
    }

    func testConciseDoesNotReadElapsedTimeFooter() {
        let s = LingShuSpokenText.concise("HTTP 是客户端和服务器之间的通信协议。\n\n⏱ 总用时 7秒")
        XCTAssertTrue(s.contains("HTTP 是客户端和服务器之间的通信协议"))
        XCTAssertFalse(s.contains("总用时"))
        XCTAssertFalse(s.contains("7秒"))
        XCTAssertFalse(s.contains("⏱"))
    }
}
