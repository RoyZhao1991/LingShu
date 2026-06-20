import XCTest
@testable import LingShuMac

/// # 确认气泡→可点击选项 解析(壳层渲染,模型无关)
final class ChoiceParsingTests: XCTestCase {

    func testParsesKeycapEnumeration() {
        // 截图里的真实格式:keycap 1️⃣/2️⃣ + "label — detail"
        let text = "⏸ 卡住,需要你定:要不要把床头灯接入系统？请选择：\n1️⃣ 接入 — 我来尝试连接 CozyLife 床头灯（局域网 TCP 5555 协议）\n2️⃣ 暂不接入 — 先不处理"
        let p = LingShuChoiceParsing.parse(text)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.options.count, 2)
        XCTAssertEqual(p?.options.first?.label, "接入")
        XCTAssertTrue(p?.options.first?.detail?.contains("CozyLife") ?? false)
        XCTAssertEqual(p?.options.last?.label, "暂不接入")
        XCTAssertTrue(p?.question.contains("床头灯") ?? false)
    }

    func testParsesNumberedAndCircled() {
        XCTAssertEqual(LingShuChoiceParsing.parse("选哪个？\n1. 方案A\n2. 方案B")?.options.count, 2)
        XCTAssertEqual(LingShuChoiceParsing.parse("确认：\n①是\n②否")?.options.map(\.label), ["是", "否"])
        XCTAssertEqual(LingShuChoiceParsing.parse("1) 接入\n2) 暂不")?.options.count, 2)
    }

    func testRejectsNonChoice() {
        XCTAssertNil(LingShuChoiceParsing.parse("床头灯已打开。"), "普通回复不是选择题")
        XCTAssertNil(LingShuChoiceParsing.parse("只有一个选项:\n1. 仅此一项"), "不足 2 项")
        XCTAssertNil(LingShuChoiceParsing.parse("第 1 步先做 A,然后做 B"), "正文里的数字不算枚举选项")
    }

    func testSplitLabelDetail() {
        let (l, d) = LingShuChoiceParsing.splitLabelDetail("**接入** — 连接灯")
        XCTAssertEqual(l, "接入")
        XCTAssertEqual(d, "连接灯")
        XCTAssertEqual(LingShuChoiceParsing.splitLabelDetail("暂不").0, "暂不")
    }
}
