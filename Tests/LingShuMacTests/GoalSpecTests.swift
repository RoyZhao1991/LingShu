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

    func testParseOutputMode() {
        let reply = LingShuGoalSpecParser.parse(#"{"objective":"只回复验收结论","kind":"task","output_mode":"chat_reply","success_criteria":["回复指定语句"]}"#)
        XCTAssertEqual(reply?.outputMode, .chatReply)
        XCTAssertEqual(reply?.isReplyOnlyOutput, true)

        let visible = LingShuGoalSpecParser.parse(#"{"objective":"演示这个 PPT","kind":"interaction","output_mode":"visible_interaction"}"#)
        XCTAssertEqual(visible?.outputMode, .visibleInteraction)
        XCTAssertEqual(visible?.allowsVisibleInteractionOutput, true)
    }

    func testParseReferenceScopeFields() {
        let spec = LingShuGoalSpecParser.parse(
            #"{"objective":"继续最近的自我介绍","kind":"question","output_mode":"chat_reply","reference_scope":"default_anchor","reference_explicit":false,"reference_evidence":["灵枢: 我是灵枢"],"success_criteria":[]}"#
        )
        XCTAssertEqual(spec?.referenceScope, .defaultAnchor)
        XCTAssertEqual(spec?.referenceExplicit, false)
        XCTAssertEqual(spec?.referenceEvidence, ["灵枢: 我是灵枢"])
        XCTAssertEqual(LingShuGoalSpecParser.parseReferenceScope("visible-context"), .visibleContext)
        XCTAssertEqual(LingShuGoalSpecParser.parseReferenceScope("task thread"), .taskThread)
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
        let spec = LingShuGoalSpec(objective: "做X", kind: .task, constraints: ["c1"], risks: ["r1"], successCriteria: ["s1"], outputMode: .artifact)
        let s = spec.summary
        XCTAssertTrue(s.contains("目标:做X(task)"))
        XCTAssertTrue(s.contains("输出模式:artifact"))
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
                                   risks: ["c"], successCriteria: ["d"], openQuestions: ["e"], outputMode: .chatReply,
                                   referenceScope: .defaultAnchor, referenceEvidence: ["用户: x"], referenceExplicit: false)
        let data = try JSONEncoder().encode(spec)
        let back = try JSONDecoder().decode(LingShuGoalSpec.self, from: data)
        XCTAssertEqual(spec, back, "GoalSpec 可往返持久化")
    }

    func testOldGoalSpecWithoutOutputModeDecodesAsUnspecified() throws {
        let json = #"{"objective":"旧目标","kind":"task","constraints":[],"boundaries":[],"risks":[],"successCriteria":[],"openQuestions":[]}"#
        let spec = try JSONDecoder().decode(LingShuGoalSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.outputMode, .unspecified)
        XCTAssertEqual(spec.referenceScope, .unknown)
        XCTAssertEqual(spec.referenceEvidence, [])
        XCTAssertEqual(spec.referenceExplicit, false)
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

    @MainActor
    func testActiveTurnGoalSpecRequestCarriesRecentForegroundContext() {
        let state = LingShuState()
        state.chatMessages = [
            .init(speaker: "你", text: "演示一下旧 PPT", isUser: true),
            .init(speaker: "灵枢", text: "旧 PPT 已经讲完。", isUser: false),
            .init(speaker: "你", text: "你是谁,介绍一下你自己", isUser: true),
            .init(speaker: "灵枢", text: "我是灵枢,一个通用智能中枢。", isUser: false),
            .init(speaker: "你", text: "继续", isUser: true),
            .init(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        ]

        let request = state.activeTurnGoalSpecRequest(for: "继续")

        let data = try! XCTUnwrap(request.data(using: .utf8))
        let json = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "lingshu_active_turn_goal_context")
        XCTAssertEqual(json["current_user_input"] as? String, "继续")
        let anchor = try! XCTUnwrap(json["default_anchor"] as? [String])
        XCTAssertTrue(anchor.contains("用户: 你是谁,介绍一下你自己"), "默认承接回合要包含最近用户问句")
        XCTAssertTrue(anchor.contains("灵枢: 我是灵枢,一个通用智能中枢。"), "默认承接回合要包含最近灵枢回答")
        let foreground = try! XCTUnwrap(json["candidate_background"] as? [String])
        XCTAssertTrue(foreground.contains("用户: 你是谁,介绍一下你自己"), "候选背景保留给大脑理解省略/续接")
        XCTAssertFalse(foreground.contains("灵枢: "), "loading 空占位不能进入候选背景")
        XCTAssertFalse(foreground.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "灵枢:" }),
                       "loading 空占位不能进入候选背景")
        XCTAssertEqual(request.components(separatedBy: "用户: 继续").count - 1, 0, "当前裸输入不能在历史前景里重复出现")
    }

    func testActiveTurnReferenceRepairFallsBackToDefaultAnchorWithoutExplicitEvidence() {
        let raw = LingShuGoalSpec(
            objective: "继续旧演示材料",
            kind: .interaction,
            outputMode: .visibleInteraction,
            referenceScope: .visibleContext,
            referenceEvidence: ["旧 PPT 已经讲完"],
            referenceExplicit: false
        )

        let repaired = LingShuState.repairActiveTurnGoalSpecReference(
            raw,
            currentInput: "继续",
            defaultAnchorLines: ["用户: 你是谁,介绍一下你自己", "灵枢: 我是灵枢,一个通用智能中枢。"]
        )

        XCTAssertEqual(repaired.referenceScope, .defaultAnchor)
        XCTAssertEqual(repaired.referenceExplicit, false)
        XCTAssertEqual(repaired.kind, .question)
        XCTAssertEqual(repaired.outputMode, .chatReply)
        XCTAssertTrue(repaired.boundaries.contains("不得跳到无显式证据的旧候选上下文"))
    }

    func testActiveTurnReferenceRepairAllowsExplicitSupportedCandidate() {
        let raw = LingShuGoalSpec(
            objective: "继续讲解当前材料",
            kind: .interaction,
            outputMode: .visibleInteraction,
            referenceScope: .visibleContext,
            referenceEvidence: ["继续讲这个 PPT"],
            referenceExplicit: true
        )

        let repaired = LingShuState.repairActiveTurnGoalSpecReference(
            raw,
            currentInput: "继续讲这个 PPT",
            defaultAnchorLines: ["用户: 你是谁", "灵枢: 我是灵枢。"]
        )

        XCTAssertEqual(repaired, raw)
    }

    func testDefaultAnchorNonInteractiveDowngradesVisibleOutputMode() {
        let raw = LingShuGoalSpec(
            objective: "继续当前对话",
            kind: .interaction,
            outputMode: .visibleInteraction,
            referenceScope: .defaultAnchor,
            referenceEvidence: ["灵枢: 我是灵枢,一个通用智能中枢。"],
            referenceExplicit: false
        )

        let repaired = LingShuState.repairActiveTurnGoalSpecReference(
            raw,
            currentInput: "继续",
            defaultAnchorLines: ["用户: 你是谁,介绍一下你自己", "灵枢: 我是灵枢,一个通用智能中枢。"],
            defaultAnchorIsInteractive: false
        )

        XCTAssertEqual(repaired.referenceScope, .defaultAnchor)
        XCTAssertEqual(repaired.kind, .question)
        XCTAssertEqual(repaired.outputMode, .chatReply)
        XCTAssertTrue(repaired.boundaries.contains("默认承接回合不是可视交互产出时不得升级为可视交互"))
    }

    func testDefaultAnchorInteractiveKeepsVisibleOutputMode() {
        let raw = LingShuGoalSpec(
            objective: "继续当前演示",
            kind: .interaction,
            outputMode: .visibleInteraction,
            referenceScope: .defaultAnchor,
            referenceEvidence: ["灵枢: 当前演示停在第 3 页。"],
            referenceExplicit: false
        )

        let repaired = LingShuState.repairActiveTurnGoalSpecReference(
            raw,
            currentInput: "继续",
            defaultAnchorLines: ["用户: 演示这份材料", "灵枢: 当前演示停在第 3 页。"],
            defaultAnchorIsInteractive: true
        )

        XCTAssertEqual(repaired, raw)
    }
}
