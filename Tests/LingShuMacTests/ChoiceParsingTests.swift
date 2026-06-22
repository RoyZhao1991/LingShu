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

    func testMultiQuestionListNotFlattenedIntoSingleChoice() {
        // 用户实测:多个确认问题(各以?结尾)被 flatten 成一个单选卡。现应**不**渲染单选卡(返回 nil),交 ask_form。
        let text = "在动手前请确认:\n1. 你在哪个城市?\n2. 饮食忌口?\n3. 每餐预算多少?\n4. 用什么支付?\n5. 健康标准是什么?"
        XCTAssertNil(LingShuChoiceParsing.parse(text), "多问题清单不应被渲染成单选卡")
    }

    func testRealAnswerOptionsStillParse() {
        // 对照:真正的"答案选项"(非问题)照常解析成单选卡。
        XCTAssertNotNil(LingShuChoiceParsing.parse("要不要接入床头灯?\n1. 接入\n2. 暂不接入"))
    }

    func testDeliveryReportFeatureListNotChoice() {
        // 用户实测:交付报告里的编号功能清单被误渲染成 8 个"选项"。现应**不**渲染选择卡。
        let report = """
        ✅ pytest 总数 299 passed, 0 failed
        ① 分账规则表 split_rule(按交易配置,支持 percentage/fixed 两种类型)
        ② 分账结算明细表 split_settlement(记录每笔交易拆给各收款方的金额)
        ③ 分账规则校验引擎:比例之和必须=100%、固定金额之和必须=净额
        ④ 分账金额计算器:按比例/固定金额拆分,含尾差自动调整
        """
        XCTAssertNil(LingShuChoiceParsing.parse(report), "交付报告里的编号功能不是选择题")
    }

    func testLongDescriptiveItemsNotChoice() {
        // 没有报告信号、但选项都是长描述(计划步骤)→ 也不是选择题(标签太长=清单)。
        let plan = "实现计划:\n1. 先搭建数据模型层和数据库访问层的完整目录结构\n2. 编写核心清分引擎并接入费率配置中心\n3. 补全多渠道拆分统计与对账差异检测逻辑"
        XCTAssertNil(LingShuChoiceParsing.parse(plan), "长描述的计划步骤不是单选项")
    }

    func testSplitLabelDetail() {
        let (l, d) = LingShuChoiceParsing.splitLabelDetail("**接入** — 连接灯")
        XCTAssertEqual(l, "接入")
        XCTAssertEqual(d, "连接灯")
        XCTAssertEqual(LingShuChoiceParsing.splitLabelDetail("暂不").0, "暂不")
    }
}
