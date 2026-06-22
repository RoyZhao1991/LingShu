import XCTest
@testable import LingShuMac

/// 通用中枢 P2·GapAnalyzer 容错解析 + 消费助手守卫(纯逻辑,无模型)。
final class GapAnalysisTests: XCTestCase {

    func testParseFeasibleNoGaps() {
        let a = LingShuGapAnalyzer.parse(#"{"feasible_now":true,"gaps":[],"note":"用 write_file 直接做"}"#)
        XCTAssertEqual(a?.feasibleNow, true)
        XCTAssertEqual(a?.gaps, [])
        XCTAssertFalse(a?.hasBlockingGap ?? true)
    }

    func testParseGapsWithKindsAndBlocking() {
        let raw = """
        ```json
        {"feasible_now":false,"note":"先接 Spotify 再做",
         "gaps":[
           {"kind":"tool","missing":"Spotify 控制工具","fill_path":"用 author_component 据 Spotify Web API 文档自写","blocking":false},
           {"kind":"human_confirmation","missing":"Spotify 账号授权","fill_path":"请你在密码管理器里授权","blocking":true}
         ]}
        ```
        """
        let a = LingShuGapAnalyzer.parse(raw)
        XCTAssertEqual(a?.feasibleNow, false)
        XCTAssertEqual(a?.gaps.count, 2)
        XCTAssertEqual(a?.gaps.first?.kind, .tool)
        XCTAssertEqual(a?.gaps.first?.blocking, false)
        XCTAssertEqual(a?.gaps.last?.kind, .humanConfirmation, "human_confirmation 应映射到 .humanConfirmation")
        XCTAssertTrue(a?.hasBlockingGap ?? false, "有 blocking 缺口")
    }

    func testParseHumanConfirmationCamelCaseToo() {
        let raw = #"{"feasible_now":false,"gaps":[{"kind":"humanConfirmation","missing":"账号授权","fill_path":"ask_user","blocking":true}]}"#
        XCTAssertEqual(LingShuGapAnalyzer.parse(raw)?.gaps.first?.kind, .humanConfirmation)
    }

    func testGapWithoutMissingFiltered() {
        let a = LingShuGapAnalyzer.parse(#"{"feasible_now":true,"gaps":[{"kind":"tool","missing":"  ","fill_path":"x"}]}"#)
        XCTAssertEqual(a?.gaps, [], "missing 空的缺口被过滤")
    }

    func testNoFeasibleFieldIsNil() {
        XCTAssertNil(LingShuGapAnalyzer.parse(#"{"gaps":[]}"#), "缺 feasible_now → 解析失败")
        XCTAssertNil(LingShuGapAnalyzer.parse("不是 JSON"))
        XCTAssertNil(LingShuGapAnalyzer.parse(""))
    }

    func testExecutionGuidanceOnlyInjectsWhenGaps() {
        let feasible = LingShuGapAnalysis(feasibleNow: true, gaps: [], note: "直接做")
        XCTAssertEqual(feasible.executionGuidance(base: "技能提示"), "技能提示", "无缺口→不加压,返回 base 原样")
        let withGap = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .knowledge, missing: "X 领域资料", fillPath: "discover_skill / web_search", blocking: false)
        ], note: "先查资料")
        let g = withGap.executionGuidance(base: "技能提示")
        XCTAssertTrue(g.hasPrefix("技能提示"))
        XCTAssertTrue(g.contains("能力缺口与补齐计划"))
        XCTAssertTrue(g.contains("X 领域资料"))
        XCTAssertTrue(withGap.executionGuidance(base: nil).contains("能力缺口"))
    }

    func testNeedsUserToUnblockAndAskDirective() {
        let needsCred = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation, missing: "账号凭据", fillPath: "请你提供", blocking: true)
        ], note: "")
        XCTAssertTrue(needsCred.needsUserToUnblock)
        XCTAssertTrue(needsCred.executionGuidance(base: nil).contains("ask_user"), "需用户提供的阻断前提→指示先 ask_user 确认")

        let selfFixable = LingShuGapAnalysis(feasibleNow: true, gaps: [
            .init(kind: .tool, missing: "某工具", fillPath: "author_component 自写", blocking: false)
        ], note: "")
        XCTAssertFalse(selfFixable.needsUserToUnblock, "能自补的工具缺口不需要用户")
        XCTAssertFalse(selfFixable.executionGuidance(base: nil).contains("ask_user"), "自补缺口→不加澄清指令")
    }

    func testSummaryReadable() {
        let a = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .device, missing: "舵机", fillPath: "接 ESP32", blocking: true)
        ], note: "需真硬件")
        let s = a.summary
        XCTAssertTrue(s.contains("当前能力不足"))
        XCTAssertTrue(s.contains("缺[device](阻断):舵机"))
        XCTAssertTrue(s.contains("策略:需真硬件"))
    }

    func testRecordPersistsTypedGapAnalysis() throws {
        var rec = LingShuTaskExecutionRecord.create(prompt: "接 Spotify 放歌")
        rec.gapAnalysis = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .tool, missing: "Spotify 工具", fillPath: "author_component", blocking: false)
        ], note: "自写")
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(LingShuTaskExecutionRecord.self, from: data)
        XCTAssertEqual(back.gapAnalysis?.gaps.first?.missing, "Spotify 工具", "缺口分析随记录跨重启持久")
        XCTAssertEqual(back.gapAnalysis?.feasibleNow, false)
    }

    @MainActor
    func testBindGapAnalysisPersistsNoGapAnalysisWithoutTimelineNoise() {
        let state = LingShuState()
        let prompt = "能力足够-\(UUID().uuidString)"
        let recordID = state.createTaskExecutionRecord(for: prompt)
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        let beforeMessages = state.taskExecutionRecords.first { $0.id == recordID }?.messages.count
        let analysis = LingShuGapAnalysis(feasibleNow: true, gaps: [], note: "现有能力可直接完成")

        state.bindGapAnalysis(analysis, to: recordID)
        state.taskExecutionJournal.flush()

        let saved = state.taskExecutionJournal.loadRecords().first { $0.id == recordID }
        XCTAssertEqual(saved?.gapAnalysis, analysis, "无缺口分析也必须作为 typed 字段持久化,不能只留内存")
        let afterMessages = state.taskExecutionRecords.first { $0.id == recordID }?.messages.count
        XCTAssertEqual(afterMessages, beforeMessages, "无缺口不应追加时间线噪声")
    }
}
