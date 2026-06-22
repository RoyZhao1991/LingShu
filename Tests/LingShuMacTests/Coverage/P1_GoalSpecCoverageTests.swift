import XCTest
@testable import LingShuMac

/// 通用中枢 **P1 目标认知**全覆盖(100 case):GoalSpec 解析鲁棒性 + 字段抽取 + kind 归一 + 执行引导组装。
/// 数据驱动:每个 case 是一条 (输入→预期) 的确定性断言,纯逻辑无模型。
final class P1_GoalSpecCoverageTests: XCTestCase {

    func testGoalSpec_100Cases() {
        var n = 0

        // —— A. objective × kind 组合(良构 JSON,50 case)——
        let objs = ["做一份季度汇报PPT", "写一个网页爬虫", "查今天北京天气",
                    "帮我规划下周出差", "把会议纪要整理出来", "给客户写封邮件",
                    "分析这份销售数据", "搭一个待办清单App", "解释什么是RAG", "订一张机票"]
        let kinds: [(String, LingShuGoalKind)] = [
            ("task", .task), ("interaction", .interaction),
            ("question", .question), ("unknown", .unknown), ("胡乱写", .unknown)
        ]
        for o in objs {
            for (ks, ke) in kinds {
                let raw = "{\"objective\":\"\(o)\",\"kind\":\"\(ks)\"}"
                let s = LingShuGoalSpecParser.parse(raw)
                XCTAssertEqual(s?.objective, o, "objective 抽取: \(raw)")
                XCTAssertEqual(s?.kind, ke, "kind 归一: \(ks)")
                n += 1
            }
        }

        // —— B. 大小写 / 带空白 / 围栏 / 夹叙 的格式鲁棒性(15 case)——
        let fmt: [(String, String)] = [
            ("{\"objective\":\"A\",\"kind\":\"TASK\"}", "A"),
            ("{\"objective\":\"B\",\"kind\":\"Task\"}", "B"),
            ("  {\"objective\":\"C\"}  ", "C"),
            ("```json\n{\"objective\":\"D\"}\n```", "D"),
            ("```\n{\"objective\":\"E\"}\n```", "E"),
            ("好的,这是结果:{\"objective\":\"F\"} 以上。", "F"),
            ("{\"objective\":\" G \"}", "G"),
            ("\n\n{\"objective\":\"H\"}\n", "H"),
            ("{\"objective\":\"I\",\"extra\":\"忽略\"}", "I"),
            ("前缀文字 {\"objective\":\"J\",\"kind\":\"question\"} 后缀", "J"),
            ("{\"kind\":\"task\",\"objective\":\"K\"}", "K"),
            ("{ \"objective\" : \"L\" }", "L"),
            ("{\"objective\":\"M\",\"constraints\":[]}", "M"),
            ("{\"objective\":\"N带中文标点,。!\"}", "N带中文标点,。!"),
            ("{\"objective\":\"O\"}\n额外解释", "O")
        ]
        for (raw, exp) in fmt {
            XCTAssertEqual(LingShuGoalSpecParser.parse(raw)?.objective, exp, "格式鲁棒: \(raw)")
            n += 1
        }

        // —— C. 应解析为 nil(无 objective / 空 / 非 JSON,12 case)——
        let nils = ["", "   ", "不是JSON", "{}", "{\"objective\":\"\"}", "{\"objective\":\"   \"}",
                    "{\"kind\":\"task\"}", "[]", "null", "{\"obj\":\"x\"}", "{\"objective\":123}", "随便一句话没有大括号"]
        for raw in nils {
            XCTAssertNil(LingShuGoalSpecParser.parse(raw), "应为 nil: \(raw)")
            n += 1
        }

        // —— D. 数组字段抽取 + 过滤空/非字符串(13 case)——
        let arrRaw = """
        {"objective":"X","kind":"task","constraints":["c1","c2",""],"boundaries":["b1"],
         "risks":["r1","r2"],"success_criteria":["s1","s2","s3"],"open_questions":["q1"]}
        """
        let sx = LingShuGoalSpecParser.parse(arrRaw)
        XCTAssertEqual(sx?.constraints, ["c1", "c2"], "空串被过滤"); n += 1
        XCTAssertEqual(sx?.boundaries, ["b1"]); n += 1
        XCTAssertEqual(sx?.risks.count, 2); n += 1
        XCTAssertEqual(sx?.successCriteria, ["s1", "s2", "s3"]); n += 1
        XCTAssertEqual(sx?.openQuestions, ["q1"]); n += 1
        XCTAssertEqual(LingShuGoalSpecParser.parse("{\"objective\":\"Y\"}")?.constraints, []); n += 1
        XCTAssertEqual(LingShuGoalSpecParser.parse("{\"objective\":\"Y\"}")?.successCriteria, []); n += 1
        XCTAssertEqual(LingShuGoalSpecParser.parse("{\"objective\":\"Y\",\"risks\":\"notarray\"}")?.risks, []); n += 1
        let mixed = LingShuGoalSpecParser.parse("{\"objective\":\"Z\",\"constraints\":[\"ok\",123,\"two\",null]}")
        XCTAssertEqual(mixed?.constraints, ["ok", "two"], "非字符串元素被过滤"); n += 1
        XCTAssertEqual(LingShuGoalSpecParser.parse("{\"objective\":\"W\",\"success_criteria\":[\"  trimmed  \"]}")?.successCriteria, ["trimmed"]); n += 1
        XCTAssertEqual(LingShuGoalSpecParser.parse("{\"objective\":\"V\",\"open_questions\":[]}")?.openQuestions, []); n += 1
        XCTAssertEqual(LingShuGoalSpecParser.parse("{\"objective\":\"U\",\"boundaries\":[\"\",\"\"]}")?.boundaries, []); n += 1
        XCTAssertEqual(LingShuGoalSpecParser.parse("{\"objective\":\"T\",\"constraints\":[\"a\"],\"risks\":[\"b\"]}")?.constraints, ["a"]); n += 1

        // —— E. 执行引导组装(executionGuidance,10 case)——
        let specFull = LingShuGoalSpec(objective: "建结算系统", kind: .task,
                                       constraints: ["不动生产库"], boundaries: ["仅 /tmp"],
                                       risks: ["并发"], successCriteria: ["有测试且全绿"], openQuestions: [])
        let g1 = specFull.executionGuidance(base: nil)
        XCTAssertTrue(g1.contains("建结算系统"), "引导含目标"); n += 1
        XCTAssertTrue(g1.contains("不动生产库"), "引导含约束"); n += 1
        XCTAssertTrue(g1.contains("仅 /tmp"), "引导含边界"); n += 1
        let g2 = specFull.executionGuidance(base: "BASE_PREFIX")
        XCTAssertTrue(g2.contains("BASE_PREFIX"), "base 被保留"); n += 1
        XCTAssertTrue(g2.hasPrefix("BASE_PREFIX"), "base 在前"); n += 1
        let specMin = LingShuGoalSpec(objective: "聊聊天", kind: .interaction)
        XCTAssertFalse(specMin.executionGuidance(base: nil).isEmpty, "最小 spec 也出引导"); n += 1
        XCTAssertTrue(specMin.executionGuidance(base: nil).contains("聊聊天")); n += 1
        let specQ = LingShuGoalSpec(objective: "什么是熵", kind: .question, openQuestions: ["要多深入"])
        XCTAssertTrue(specQ.executionGuidance(base: nil).contains("什么是熵")); n += 1
        XCTAssertEqual(LingShuGoalSpec(objective: "x").kind, .unknown, "默认 kind=unknown"); n += 1
        XCTAssertEqual(specFull, specFull, "Equatable 自反"); n += 1

        XCTAssertGreaterThanOrEqual(n, 100, "P1 覆盖应 ≥100 case,实际 \(n)")
    }
}
