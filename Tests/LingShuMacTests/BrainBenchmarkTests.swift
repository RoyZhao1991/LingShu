import XCTest
@testable import LingShuMac

/// # 内置脑力测试 题库判分 + 综合评分 测试
final class BrainBenchmarkTests: XCTestCase {

    private func grade(_ id: String, _ reply: String) -> Bool {
        guard let item = LingShuBrainBenchmark.items.first(where: { $0.id == id }) else {
            XCTFail("无此题 \(id)"); return false
        }
        return item.grade(reply)
    }

    // MARK: - 逐题判分(正确答案过 / 错误答案不过)

    func testGradersAcceptCorrectAnswers() {
        XCTAssertTrue(grade("e_arith", "115"))
        XCTAssertTrue(grade("e_arith", "答案是 115。"))
        XCTAssertTrue(grade("e_chem", "H2O"))
        XCTAssertTrue(grade("e_chem", "水的分子式是 H₂O"))
        XCTAssertTrue(grade("e_instr", "收到"))
        XCTAssertTrue(grade("m_animals", "5"))
        XCTAssertTrue(grade("m_weekday", "星期六"))
        XCTAssertTrue(grade("m_json", "{\"name\":\"张三\",\"age\":28,\"job\":\"工程师\"}"))
        XCTAssertTrue(grade("m_json", "```json\n{\"name\": \"张三\", \"age\": \"28\", \"job\": \"工程师\"}\n```"))
        XCTAssertTrue(grade("h_logic", "乙"))
        XCTAssertTrue(grade("h_sum", "1683"))
    }

    func testGradersRejectWrongAnswers() {
        XCTAssertFalse(grade("e_arith", "116"))
        XCTAssertFalse(grade("e_chem", "CO2"))
        XCTAssertFalse(grade("e_instr", "收到!这是一段很长的多余解释说明文字啰嗦"))  // 没遵循"只两个字"
        XCTAssertFalse(grade("m_animals", "鸡有3只"))
        XCTAssertFalse(grade("m_weekday", "星期五"))
        XCTAssertFalse(grade("m_json", "{\"name\":\"李四\",\"age\":28,\"job\":\"工程师\"}"))
        XCTAssertFalse(grade("h_logic", "甲是第一名"))
        XCTAssertFalse(grade("h_sum", "1530"))
    }

    // MARK: - 综合评分

    func testCompositeAllPassedIs100() {
        let all = Set(LingShuBrainBenchmark.items.map(\.id))
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: all), 100)
    }

    func testCompositeNonePassedIsZero() {
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: []), 0)
    }

    func testCompositeWeightsByDifficulty() {
        // 只过 3 道易题(权重各 1,总权重 15)→ 3/15 = 20。
        let easyIDs = Set(LingShuBrainBenchmark.items.filter { $0.difficulty == .easy }.map(\.id))
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: easyIDs), 20)
        // 只过 2 道难题(权重各 3)→ 6/15 = 40。
        let hardIDs = Set(LingShuBrainBenchmark.items.filter { $0.difficulty == .hard }.map(\.id))
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: hardIDs), 40)
    }

    func testBatteryShape() {
        XCTAssertEqual(LingShuBrainBenchmark.items.count, 8)
        XCTAssertEqual(LingShuBrainBenchmark.totalWeight, 15)
        XCTAssertEqual(Set(LingShuBrainBenchmark.items.map(\.id)).count, 8, "题 id 不重复")
    }

    func testResultGradeBands() {
        func g(_ s: Int) -> String { LingShuBrainBenchmarkResult(brainID: "x", score: s, passedCount: 0, totalCount: 8, rows: []).grade }
        XCTAssertEqual(g(95), "卓越")
        XCTAssertEqual(g(80), "优秀")
        XCTAssertEqual(g(65), "良好")
        XCTAssertEqual(g(50), "及格")
        XCTAssertEqual(g(20), "偏弱")
    }
}
