import XCTest
@testable import LingShuMac

/// 通用中枢 P1·GoalSpec 容错解析守卫(纯逻辑,无模型)。
final class GoalSpecTests: XCTestCase {

    func testParseCleanJSON() {
        let raw = """
        {"objective":"做一份Q3财报PPT","kind":"task","constraints":["10页内","用公司模板"],
         "boundaries":["不编造数据"],"risks":["含财务敏感数据"],
         "success_criteria":["PPT文件存在","含营收图表"],"open_questions":["数据源在哪"]}
        """
        let spec = LingShuGoalSpecParser.parse(raw)
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.objective, "做一份Q3财报PPT")
        XCTAssertEqual(spec?.kind, .task)
        XCTAssertEqual(spec?.constraints, ["10页内", "用公司模板"])
        XCTAssertEqual(spec?.risks, ["含财务敏感数据"])
        XCTAssertEqual(spec?.successCriteria.count, 2)
        XCTAssertEqual(spec?.openQuestions, ["数据源在哪"])
    }

    func testParseStripsMarkdownFenceAndProse() {
        let raw = """
        好的,这是解析结果:
        ```json
        {"objective":"查一下今天天气", "kind":"question"}
        ```
        希望有帮助!
        """
        let spec = LingShuGoalSpecParser.parse(raw)
        XCTAssertEqual(spec?.objective, "查一下今天天气")
        XCTAssertEqual(spec?.kind, .question)
        XCTAssertEqual(spec?.constraints, [], "缺省数组应为空,不崩")
    }

    func testKindFallbackUnknownAndTrim() {
        let raw = #"{"objective":"  陪我聊聊  ","kind":"瞎写的","constraints":["  ",""]}"#
        let spec = LingShuGoalSpecParser.parse(raw)
        XCTAssertEqual(spec?.objective, "陪我聊聊", "objective 去空白")
        XCTAssertEqual(spec?.kind, .unknown, "未知 kind 兜底 unknown")
        XCTAssertEqual(spec?.constraints, [], "空白项被过滤")
    }

    func testInteractionKind() {
        XCTAssertEqual(LingShuGoalSpecParser.parse(#"{"objective":"给客户演示产品","kind":"interaction"}"#)?.kind, .interaction)
    }

    func testNoObjectiveIsNil() {
        XCTAssertNil(LingShuGoalSpecParser.parse(#"{"kind":"task","constraints":["x"]}"#), "无 objective = 解析失败")
        XCTAssertNil(LingShuGoalSpecParser.parse(#"{"objective":"   "}"#), "空 objective = 解析失败")
    }

    func testGarbageIsNil() {
        XCTAssertNil(LingShuGoalSpecParser.parse("这根本不是 JSON"))
        XCTAssertNil(LingShuGoalSpecParser.parse(""))
        XCTAssertNil(LingShuGoalSpecParser.parse("{ 坏掉的 json"))
    }

    func testSummaryReadable() {
        let spec = LingShuGoalSpec(objective: "做X", kind: .task, constraints: ["c1"], risks: ["r1"], successCriteria: ["s1"])
        let s = spec.summary
        XCTAssertTrue(s.contains("目标:做X(task)"))
        XCTAssertTrue(s.contains("约束:c1"))
        XCTAssertTrue(s.contains("成功标准:s1"))
        XCTAssertFalse(s.contains("边界:"), "空字段不出现在摘要")
    }

    // MARK: P1b 消费助手(纯逻辑)

    func testExecutionGuidanceMergesWithBase() {
        let spec = LingShuGoalSpec(objective: "做X", kind: .task, constraints: ["c1"])
        let withBase = spec.executionGuidance(base: "技能提示")
        XCTAssertTrue(withBase.hasPrefix("技能提示"), "已有 guidance 在前")
        XCTAssertTrue(withBase.contains("本次目标"), "目标块拼在后")
        XCTAssertTrue(withBase.contains("做X"))
        let noBase = spec.executionGuidance(base: nil)
        XCTAssertTrue(noBase.contains("本次目标"))
        XCTAssertFalse(noBase.hasPrefix("\n"), "无 base 不前导空行")
        XCTAssertEqual(spec.executionGuidance(base: "   "), spec.executionGuidance(base: nil), "空白 base 视同无")
    }

    func testExecutionGuidanceInstructsAskUserWhenOpenQuestions() {
        let withQ = LingShuGoalSpec(objective: "做X", kind: .task, openQuestions: ["数据源在哪"])
        XCTAssertTrue(withQ.executionGuidance(base: nil).contains("ask_user"), "有待澄清→指示先 ask_user")
        let noQ = LingShuGoalSpec(objective: "做X", kind: .task)
        XCTAssertFalse(noQ.executionGuidance(base: nil).contains("ask_user"), "无待澄清→不加澄清指令")
    }

    func testAcceptanceCriteriaBlockEmptyWhenNoCriteria() {
        XCTAssertEqual(LingShuGoalSpec(objective: "做X").acceptanceCriteriaBlock, "", "无成功标准→空串(不给验收官加压)")
        let withC = LingShuGoalSpec(objective: "做X", successCriteria: ["报告完整", "周五前交付"])
        XCTAssertTrue(withC.acceptanceCriteriaBlock.contains("成功标准"))
        XCTAssertTrue(withC.acceptanceCriteriaBlock.contains("- 报告完整"))
        XCTAssertTrue(withC.acceptanceCriteriaBlock.contains("- 周五前交付"))
    }

    func testCodableRoundTrip() throws {
        let spec = LingShuGoalSpec(objective: "目标", kind: .task, constraints: ["a"], boundaries: ["b"],
                                   risks: ["c"], successCriteria: ["d"], openQuestions: ["e"])
        let data = try JSONEncoder().encode(spec)
        let back = try JSONDecoder().decode(LingShuGoalSpec.self, from: data)
        XCTAssertEqual(spec, back, "GoalSpec 可往返持久化")
    }

    // MARK: 持久化:GoalSpec 作为 typed 字段随任务记录跨重启(Item 1)

    func testRecordPersistsTypedGoalSpec() throws {
        var rec = LingShuTaskExecutionRecord.create(prompt: "做X")
        rec.goalSpec = LingShuGoalSpec(objective: "做X", kind: .task, successCriteria: ["s1"])
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: data)
        XCTAssertEqual(back.goalSpec?.objective, "做X", "重启后记录里仍拿得到 typed GoalSpec")
        XCTAssertEqual(back.goalSpec?.successCriteria, ["s1"])
    }

    func testOldRecordWithoutGoalSpecDecodesNil() throws {
        // 旧持久化记录无 goalSpec 键 → decodeIfPresent 兜 nil(向后兼容,不崩)。
        let json = #"{"id":"r1","title":"t","prompt":"p","status":"已完成","summary":"s","participants":["你"],"createdAt":0,"updatedAt":0,"messages":[]}"#
        let rec = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: Data(json.utf8))
        XCTAssertNil(rec.goalSpec, "老记录无 goalSpec 字段→nil")
    }
}
