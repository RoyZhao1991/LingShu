import XCTest
@testable import LingShuMac

/// Record & Replay 过程型技能守卫(纯逻辑):SKILL.md 读写 / 参数替换 / 录制识别 / replay 匹配抽参。
final class ProcedureSkillTests: XCTestCase {

    private func sampleMarkdown() -> String {
        """
        ---
        id: expense
        title: 报销技能
        kind: procedure
        triggers: 报销, 填报销单, 报销技能
        app: 办公审批
        ---

        ## 操作步骤
        1. 打开「办公审批」
        2. 点「费用报销」
        3. 科目选「差旅费」
        4. 金额填 {{金额}}
        5. 日期填 {{日期}}
        6. 审批人选 {{审批人}}
        7. 点「提交」

        ## 参数
        - 金额: 报销金额(例 3600)
        - 日期: 报销日期(例 6月15号)
        - 审批人: 审批人(例 部门领导)
        """
    }

    func testParseProcedureSkill() {
        let s = LingShuProcedureSkill.parse(markdown: sampleMarkdown(), fallbackID: "x")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.title, "报销技能")
        XCTAssertEqual(s?.appHint, "办公审批")
        XCTAssertEqual(s?.triggers, ["报销", "填报销单", "报销技能"])
        XCTAssertEqual(s?.steps.count, 7)
        XCTAssertEqual(s?.steps[3], "金额填 {{金额}}")
        XCTAssertEqual(s?.parameters.map(\.name), ["金额", "日期", "审批人"])
        XCTAssertEqual(s?.parameters.first?.example, "3600")
    }

    func testNonProcedureMarkdownIgnored() {
        // 普通专家技能(无 kind: procedure)不归过程技能管。
        let md = "---\ntitle: 设计专家\ntriggers: 设计\n---\n## 专业要点\n- 配色\n"
        XCTAssertNil(LingShuProcedureSkill.parse(markdown: md, fallbackID: "x"))
    }

    func testMarkdownRoundTrip() {
        let original = LingShuProcedureSkill.parse(markdown: sampleMarkdown(), fallbackID: "x")!
        let reparsed = LingShuProcedureSkill.parse(markdown: original.toMarkdown(), fallbackID: "x")
        XCTAssertEqual(reparsed?.steps, original.steps)
        XCTAssertEqual(reparsed?.parameters.map(\.name), original.parameters.map(\.name))
        XCTAssertEqual(reparsed?.triggers, original.triggers)
    }

    func testResolvedStepsAndMissing() {
        let s = LingShuProcedureSkill.parse(markdown: sampleMarkdown(), fallbackID: "x")!
        let resolved = s.resolvedSteps(["金额": "4800", "日期": "6月20号"])
        XCTAssertEqual(resolved[3], "金额填 4800")
        XCTAssertEqual(resolved[4], "日期填 6月20号")
        XCTAssertEqual(resolved[5], "审批人选 {{审批人}}", "没给的参数占位保留")
        XCTAssertEqual(s.missingParameters(given: ["金额": "4800", "日期": "6月20号"]), ["审批人"])
    }

    // MARK: 路由

    func testDetectRecordRequest() {
        XCTAssertEqual(LingShuProcedureSkillRouter.detectRecordRequest("记录一个技能叫报销")?.name, "报销")
        XCTAssertEqual(LingShuProcedureSkillRouter.detectRecordRequest("看我做一遍")?.name, nil)
        XCTAssertNil(LingShuProcedureSkillRouter.detectRecordRequest("帮我演示一下这个文档"), "非录制请求不拦")
    }

    func testMatchReplayAndExtractParams() {
        let skill = LingShuProcedureSkill.parse(markdown: sampleMarkdown(), fallbackID: "x")!
        let m = LingShuProcedureSkillRouter.matchReplay("用报销技能,金额4800,日期6月20号", skills: [skill])
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.skill.id, "expense")
        XCTAssertEqual(m?.params["金额"], "4800")
        XCTAssertEqual(m?.params["日期"], "6月20号")
    }

    func testReplayNeedsExecutionIntent() {
        let skill = LingShuProcedureSkill.parse(markdown: sampleMarkdown(), fallbackID: "x")!
        // 只是聊到"报销"没执行意图 → 不触发 replay。
        XCTAssertNil(LingShuProcedureSkillRouter.matchReplay("这个月报销好麻烦", skills: [skill]))
        // 触发词开头(报销...)算意图。
        XCTAssertNotNil(LingShuProcedureSkillRouter.matchReplay("报销技能,金额5000", skills: [skill]))
    }
}
