import XCTest
@testable import LingShuMac

/// 通用中枢 **P4 经验闭环**全覆盖(100 case):字符二元组 Jaccard 相似度 + 最相关召回(阈值/排序/限量/自排除)+
/// 引导块组装 + 成功判定。纯逻辑无模型。
final class P4_GoalExperienceCoverageTests: XCTestCase {

    private func exp(_ obj: String, _ outcome: String = "已完成", lesson: String = "L", src: String? = nil) -> LingShuGoalExperience {
        LingShuGoalExperience(objective: obj, kind: "task", outcome: outcome, lesson: lesson, sourceRecordID: src)
    }
    private typealias M = LingShuGoalExperienceMatch

    func testGoalExperience_100Cases() {
        var n = 0
        let acc = 1e-9

        // —— A. relevance 精确值(20 case)——
        let rel: [(String, String, Double)] = [
            ("abc", "abc", 1.0), ("ab", "ab", 1.0), ("a", "a", 1.0),
            ("a", "b", 0.0), ("abc", "xyz", 0.0),
            ("abc", "abd", 1.0 / 3.0),           // {ab,bc} vs {ab,bd}
            ("abcd", "abcd", 1.0),
            ("ABC", "abc", 1.0),                 // 大小写不敏感
            ("a-b-c", "abc", 1.0),               // 标点过滤
            ("a b c", "abc", 1.0),               // 空白过滤
            ("", "abc", 0.0), ("abc", "", 0.0), ("", "", 0.0),
            ("hello", "hello", 1.0),
            ("hello", "hellp", 3.0 / 5.0),       // {he,el,ll,lo} vs {he,el,ll,lp} ∩3/∪5=0.6
            ("abcd", "abxy", 1.0 / 5.0),         // {ab,bc,cd} vs {ab,bx,xy} ∩{ab}=1 ∪5
            ("notion", "notion库", 5.0 / 6.0),   // {no,ot,ti,io,on}(5) ⊂ +{n库}(6) → ∩5/∪6
            ("12", "12", 1.0), ("12", "34", 0.0),
            ("test123", "test456", 3.0 / 7.0)    // {te,es,st,t1,12,23} vs {te,es,st,t4,45,56} ∩3/∪9 ... 重算下方
        ]
        for (a, b, e) in rel {
            // 末条特例:test123 vs test456 → {te,es,st,t1,12,23}(6) vs {te,es,st,t4,45,56}(6),∩{te,es,st}=3,∪=9 → 1/3
            let expected = (a == "test123") ? (3.0 / 9.0) : e
            XCTAssertEqual(M.relevance(a, b), expected, accuracy: acc, "relevance(\(a),\(b))")
            n += 1
        }

        // —— B. relevance 单调/对称(15 case)——
        XCTAssertEqual(M.relevance("notion同步", "notion同步"), 1.0, accuracy: acc); n += 1
        XCTAssertEqual(M.relevance("a", "b"), M.relevance("b", "a"), accuracy: acc, "对称"); n += 1
        XCTAssertGreaterThan(M.relevance("做PPT汇报", "做PPT总结"), M.relevance("做PPT汇报", "查天气预报")); n += 1
        XCTAssertGreaterThanOrEqual(M.relevance("abc", "abc"), M.relevance("abc", "abd")); n += 1
        XCTAssertGreaterThanOrEqual(M.relevance("abc", "abd"), M.relevance("abc", "xyz")); n += 1
        for (a, b) in [("同步Notion", "同步Notion待办"), ("写爬虫", "写一个爬虫"), ("订机票", "订一张机票"),
                       ("分析数据", "分析销售数据"), ("做设计", "做UI设计")] {
            XCTAssertGreaterThan(M.relevance(a, b), 0.0, "相关>0: \(a)/\(b)"); n += 1
            XCTAssertLessThanOrEqual(M.relevance(a, b), 1.0); n += 1
        }

        // —— C. bigrams(10 case)——
        XCTAssertEqual(M.bigrams("abc"), ["ab", "bc"]); n += 1
        XCTAssertEqual(M.bigrams("a"), ["a"]); n += 1
        XCTAssertEqual(M.bigrams(""), []); n += 1
        XCTAssertEqual(M.bigrams("aa"), ["aa"]); n += 1
        XCTAssertEqual(M.bigrams("a!b"), ["ab"], "标点过滤后相邻成 bigram"); n += 1
        XCTAssertEqual(M.bigrams("AB"), ["ab"], "小写归一"); n += 1
        XCTAssertEqual(M.bigrams("abca").count, 3, "{ab,bc,ca}"); n += 1
        XCTAssertEqual(M.bigrams("  ").count, 0, "全空白→空"); n += 1
        XCTAssertEqual(M.bigrams("12345").count, 4); n += 1
        XCTAssertTrue(M.bigrams("hello").contains("ll")); n += 1

        // —— D. mostRelevant:阈值/排序/限量/自排除(30 case)——
        let lib = [exp("把待办同步到Notion数据库", src: "r1"), exp("同步今日待办到Notion", src: "r2"),
                   exp("做季度汇报PPT", src: "r3"), exp("查北京天气", src: "r4"), exp("把笔记同步到Notion", src: "r5")]
        let m1 = M.mostRelevant(lib, to: "同步待办到Notion", limit: 2)
        XCTAssertEqual(m1.count, 2, "限量2"); n += 1
        XCTAssertTrue(m1.allSatisfy { $0.objective.contains("Notion") }, "召回的都相关"); n += 1
        XCTAssertGreaterThanOrEqual(M.relevance(m1[0].objective, "同步待办到Notion"),
                                    M.relevance(m1[1].objective, "同步待办到Notion"), "降序"); n += 1
        let m2 = M.mostRelevant(lib, to: "同步待办到Notion", limit: 5)
        XCTAssertLessThanOrEqual(m2.count, 5); n += 1
        XCTAssertFalse(m2.contains { $0.objective == "查北京天气" }, "无关的不召回(阈值)"); n += 1
        let m3 = M.mostRelevant(lib, to: "完全无关的火星探测任务", limit: 3)
        XCTAssertTrue(m3.isEmpty, "全不过阈值→空"); n += 1
        // 自排除:排除 r1 后不含它
        let m4 = M.mostRelevant(lib, to: "把待办同步到Notion数据库", limit: 5, excludingSourceRecordID: "r1")
        XCTAssertFalse(m4.contains { $0.sourceRecordID == "r1" }, "排除当前任务自身"); n += 1
        // 不排除时,完全相同目标必召回(P4 修过的真风险点)
        let m5 = M.mostRelevant(lib, to: "把待办同步到Notion数据库", limit: 1)
        XCTAssertEqual(m5.first?.sourceRecordID, "r1", "完全相同历史目标必召回"); n += 1
        // limit 边界
        XCTAssertEqual(M.mostRelevant(lib, to: "Notion", limit: 1).count, 1); n += 1
        XCTAssertTrue(M.mostRelevant(lib, to: "Notion", limit: 0).isEmpty, "limit 0 → 空"); n += 1
        XCTAssertTrue(M.mostRelevant([], to: "任何", limit: 3).isEmpty, "空库 → 空"); n += 1
        // 阈值 threshold 自定义
        let m6 = M.mostRelevant(lib, to: "做PPT", limit: 5, threshold: 0.9)
        XCTAssertTrue(m6.isEmpty, "高阈值 0.9 → 几乎召不回"); n += 1
        let m7 = M.mostRelevant(lib, to: "同步今日待办到Notion", limit: 5, threshold: 0.01)
        XCTAssertGreaterThanOrEqual(m7.count, 3, "低阈值 → 召回更多"); n += 1
        // 更多确定性召回断言
        for q in ["Notion同步", "同步到Notion", "Notion待办"] {
            let mm = M.mostRelevant(lib, to: q, limit: 3)
            XCTAssertFalse(mm.isEmpty, "「\(q)」应有召回"); n += 1
            XCTAssertTrue(mm.allSatisfy { M.relevance($0.objective, q) >= 0.2 }, "召回均过阈值"); n += 1
        }
        // 排序稳定:第一条相关度最高
        let ranked = M.mostRelevant(lib, to: "把待办同步到Notion数据库", limit: 5)
        for i in 1..<ranked.count {
            XCTAssertGreaterThanOrEqual(M.relevance(ranked[i-1].objective, "把待办同步到Notion数据库"),
                                        M.relevance(ranked[i].objective, "把待办同步到Notion数据库"), "全局降序")
            n += 1
        }
        XCTAssertEqual(M.mostRelevant(lib, to: "查北京天气", limit: 2).first?.objective, "查北京天气"); n += 1
        XCTAssertEqual(M.mostRelevant(lib, to: "做季度汇报PPT", limit: 1).first?.objective, "做季度汇报PPT"); n += 1

        // —— E. guidanceBlock(10 case)——
        XCTAssertEqual(M.guidanceBlock(from: [], base: "BASE"), "BASE", "无经验→base 原样"); n += 1
        XCTAssertEqual(M.guidanceBlock(from: [], base: nil), "", "无经验+无base→空"); n += 1
        let gb = M.guidanceBlock(from: [exp("做PPT", "失败", lesson: "配色乱")], base: nil)
        XCTAssertTrue(gb.contains("做PPT"), "含目标"); n += 1
        XCTAssertTrue(gb.contains("失败"), "含结果"); n += 1
        XCTAssertTrue(gb.contains("配色乱"), "含教训"); n += 1
        XCTAssertTrue(gb.contains("历史经验"), "含标题"); n += 1
        let gb2 = M.guidanceBlock(from: [exp("做PPT", lesson: "用DesignKB")], base: "PREFIX")
        XCTAssertTrue(gb2.hasPrefix("PREFIX"), "base 在前"); n += 1
        XCTAssertTrue(gb2.contains("用DesignKB")); n += 1
        let gb3 = M.guidanceBlock(from: [exp("a"), exp("b")], base: nil)
        XCTAssertTrue(gb3.contains("a") && gb3.contains("b"), "多条都在"); n += 1
        XCTAssertFalse(M.guidanceBlock(from: [exp("x")], base: "  ").isEmpty); n += 1

        // —— F. succeeded(15 case)——
        let succ: [(String, Bool)] = [
            ("已完成", true), ("已核验完成", true), ("已直接回答", true),
            ("失败", false), ("未达标", false), ("部分完成", false),
            ("已暂停", false), ("阻断", false), ("waitingForUser", false),
            ("", false), ("完成了吧", false), ("已完成 ", false),   // 末尾空格→非精确匹配
            ("已 完成", false), ("verified", false), ("partial", false)
        ]
        for (o, e) in succ {
            XCTAssertEqual(exp("obj", o).succeeded, e, "succeeded(\(o))")
            n += 1
        }

        // —— G. 补充:relevance 自反 + 召回稳健(12 case)——
        for s in ["同步Notion", "做PPT", "查天气", "写爬虫", "订机票", "建中台"] {
            XCTAssertEqual(M.relevance(s, s), 1.0, accuracy: acc, "自反=1: \(s)"); n += 1
        }
        let lib2 = [exp("把待办同步到Notion数据库", src: "a"), exp("同步今日待办到Notion", src: "b")]
        for q in ["把待办同步到Notion数据库", "同步今日待办到Notion", "待办同步到Notion"] {
            XCTAssertFalse(M.mostRelevant(lib2, to: q, limit: 2).isEmpty, "「\(q)」有召回"); n += 1
        }
        XCTAssertEqual(M.mostRelevant(lib2, to: "完全无关火星", limit: 2).count, 0); n += 1
        XCTAssertLessThanOrEqual(M.mostRelevant(lib2, to: "Notion", limit: 1).count, 1); n += 1
        XCTAssertGreaterThan(M.relevance("a", "a"), M.relevance("a", "z")); n += 1

        XCTAssertGreaterThanOrEqual(n, 100, "P4 覆盖应 ≥100 case,实际 \(n)")
    }
}
