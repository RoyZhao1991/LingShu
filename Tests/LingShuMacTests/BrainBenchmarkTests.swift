import XCTest
@testable import LingShuMac

/// # 内置脑力测试(37 题)判分 + 综合评分 测试
final class BrainBenchmarkTests: XCTestCase {

    private func grade(_ id: String, _ reply: String, usedTools: Bool = false) -> Bool {
        guard let item = LingShuBrainBenchmark.items.first(where: { $0.id == id }) else {
            XCTFail("无此题 \(id)"); return false
        }
        return item.grade(reply, usedTools)
    }

    // MARK: - reasoning 正确答案过

    func testReasoningAcceptsCorrect() {
        XCTAssertTrue(grade("e_arith", "115"))
        XCTAssertTrue(grade("e_chem", "H₂O"))
        XCTAssertTrue(grade("e_capital", "北京"))
        XCTAssertTrue(grade("e_apple", "apple"))
        XCTAssertTrue(grade("m_animals", "5"))
        XCTAssertTrue(grade("m_race", "乙"))
        XCTAssertTrue(grade("m_batball", "0.05 元"))
        XCTAssertTrue(grade("m_decimal", "后者"))
        XCTAssertTrue(grade("m_strawberry", "3"))
        XCTAssertTrue(grade("m_machines", "5"))
        XCTAssertTrue(grade("m_sort", "9,6,5,4,3,2,1,1"))
        XCTAssertTrue(grade("m_json", "{\"name\":\"张三\",\"age\":28,\"job\":\"工程师\"}"))
        XCTAssertTrue(grade("h_lilypad", "47"))
        XCTAssertTrue(grade("h_syllogism", "无效"))
        XCTAssertTrue(grade("h_clock", "7.5"))
        XCTAssertTrue(grade("h_reverse", "keeSpeeD"))
        XCTAssertTrue(grade("h_percent", "96"))
    }

    // MARK: - reasoning 已知失误答案不过(区分点)

    func testReasoningRejectsWrong() {
        XCTAssertFalse(grade("e_arith", "116"))
        XCTAssertFalse(grade("m_batball", "0.10 元"), "认知反射陷阱:0.10 是错的")
        XCTAssertFalse(grade("m_decimal", "前者"), "9.11>9.9 是错的")
        XCTAssertFalse(grade("m_strawberry", "2"), "strawberry 里有 3 个 r,不是 2")
        XCTAssertFalse(grade("m_machines", "100 分钟"), "认知反射陷阱:不是 100")
        XCTAssertFalse(grade("h_lilypad", "24"), "翻倍题:半湖是第 47 天不是 24")
        XCTAssertFalse(grade("h_syllogism", "有效"), "这是无效三段论")
        XCTAssertFalse(grade("h_mult", "411"))
    }

    // MARK: - agentic:答案对 **且** 真调过工具才过

    func testAgenticRequiresAnswerAndTools() {
        XCTAssertTrue(grade("a_sum", "运行得到 500500", usedTools: true))
        XCTAssertTrue(grade("a_factorial", "20! = 2432902008176640000", usedTools: true))
        XCTAssertTrue(grade("a_bigmult", "结果是 121932631112635269", usedTools: true))
        XCTAssertFalse(grade("a_sum", "结果是 500500", usedTools: false), "没调工具(口算/摆烂)不算")
        XCTAssertFalse(grade("a_factorial", "2432902008176640000", usedTools: false))
        XCTAssertFalse(grade("a_bigmult", "121932631112635269", usedTools: false))
    }

    // MARK: - 综合评分

    func testCompositeAllPassedIs100() {
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: Set(LingShuBrainBenchmark.items.map(\.id))), 100)
    }

    func testCompositeNonePassedIsZero() {
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: []), 0)
    }

    func testCompositeWeightsByDifficulty() {
        // 总权重 144(易 7×1 + 中 15×2 + 难 15×3 + 极难 9 题=62:5 长链编码 30 + 4 前沿 32)。
        let easyIDs = Set(LingShuBrainBenchmark.items.filter { $0.difficulty == .easy }.map(\.id))
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: easyIDs), 5, "7/144≈5")
        let hardIDs = Set(LingShuBrainBenchmark.items.filter { $0.difficulty == .hard }.map(\.id))
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: hardIDs), 31, "45/144≈31")
        let expertIDs = Set(LingShuBrainBenchmark.items.filter { $0.difficulty == .expert }.map(\.id))
        XCTAssertEqual(LingShuBrainBenchmark.composite(passedIDs: expertIDs), 43, "62/144≈43 — 极难/前沿编码题占 ~43% 权重,差距由它主导")
    }

    func testBatteryShapeWideSpread() {
        XCTAssertGreaterThanOrEqual(LingShuBrainBenchmark.items.count, 30, "至少 30 题")
        XCTAssertEqual(LingShuBrainBenchmark.items.count, 46)
        XCTAssertEqual(LingShuBrainBenchmark.totalWeight, 144)
        XCTAssertEqual(Set(LingShuBrainBenchmark.items.map(\.id)).count, LingShuBrainBenchmark.items.count, "题 id 不重复")
        XCTAssertEqual(LingShuBrainBenchmark.items.filter(\.agentic).count, 14, "14 道 agentic(5 计算 + 5 长链编码 + 4 前沿)")
        for d in LingShuBrainBenchmark.Difficulty.allCases {
            XCTAssertGreaterThan(LingShuBrainBenchmark.items.filter { $0.difficulty == d }.count, 0, "难度 \(d) 应有题")
        }
    }

    func testCodeTasksHaveHiddenHarness() {
        let coded = LingShuBrainBenchmark.items.filter { $0.codeCheck != nil }
        XCTAssertEqual(coded.count, 9, "9 道隐藏用例判分的编码题(5 长链 + 4 前沿)")
        for it in coded {
            XCTAssertTrue(it.codeCheck!.harness.contains("BENCH_PASS"), "\(it.id) 的 harness 应以 BENCH_PASS 判过")
            XCTAssertTrue(it.prompt.contains("{DIR}"), "\(it.id) 的 prompt 应含 {DIR} 占位(runner 替换成隔离目录)")
            XCTAssertEqual(it.difficulty, .expert)
        }
    }

    func testResultGradeBands() {
        func g(_ s: Int) -> String { LingShuBrainBenchmarkResult(brainID: "x", score: s, passedCount: 0, totalCount: 37, rows: []).grade }
        XCTAssertEqual(g(95), "卓越"); XCTAssertEqual(g(80), "优秀"); XCTAssertEqual(g(65), "良好")
        XCTAssertEqual(g(50), "及格"); XCTAssertEqual(g(20), "偏弱")
    }
}
