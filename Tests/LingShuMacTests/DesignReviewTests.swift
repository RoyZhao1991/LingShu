import XCTest
@testable import LingShuMac

/// 过程内设计审计(Phase B)+ 设计经验自进化(Phase C)的纯逻辑测试。
final class DesignReviewTests: XCTestCase {
    typealias Dream = LingShuDreamingConsolidator

    // MARK: Phase B — VL 评分解析

    func testParseDesignScore() {
        XCTAssertEqual(LingShuState.parseDesignScore("score=0.82 | 标题略挤")!, 0.82, accuracy: 0.001)
        XCTAssertEqual(LingShuState.parseDesignScore("分数=0.9,版式不错")!, 0.9, accuracy: 0.001)
        XCTAssertEqual(LingShuState.parseDesignScore("这页 0.65 还行")!, 0.65, accuracy: 0.001)
        XCTAssertEqual(LingShuState.parseDesignScore("评分 8/10")!, 0.8, accuracy: 0.001)   // x/10
        XCTAssertEqual(LingShuState.parseDesignScore("设计 75分")!, 0.75, accuracy: 0.001)  // 百分制
        XCTAssertNil(LingShuState.parseDesignScore("这页排版挺好的没问题"))                  // 无数字 → nil(不假失败)
    }

    func testDeriveDesignScoreFromDescription() {
        // 描述型 VL(无 score=)→ 从问题关键词推分:有问题 0.5、干净 0.8、空 nil。
        let bad = LingShuState.deriveDesignScoreFromDescription("标题和图片有重叠,右侧文字被截断")
        XCTAssertEqual(bad?.score, 0.5)
        XCTAssertTrue(bad?.issue.contains("重叠") ?? false)
        XCTAssertEqual(LingShuState.deriveDesignScoreFromDescription("一张排版整洁的封面,层级清晰")?.score, 0.8)
        XCTAssertNil(LingShuState.deriveDesignScoreFromDescription("  "))
    }

    func testParseDesignIssue() {
        XCTAssertEqual(LingShuState.parseDesignIssue("score=0.5 | 文字和图片重叠"), "文字和图片重叠")
        XCTAssertTrue(LingShuState.parseDesignIssue("score=0.9 OK").contains("OK"))
    }

    // MARK: Phase C — 设计经验自进化(从评分提炼,红线净化)

    func testConsolidateDesignInsightsNeedsEnoughSamples() async {
        let few = [Dream.DesignSample(prompt: "做ppt", score: 0.8, liked: nil, issues: [])]
        let r = await Dream.consolidateDesignInsights(samples: few) { _ in "- 用满版图封面" }
        XCTAssertNil(r, "样本不足 3 条不应产出设计经验")
    }

    func testConsolidateDesignInsightsSanitizesAndBuilds() async {
        let samples = [
            Dream.DesignSample(prompt: "做产品 ppt", score: 0.9, liked: true, issues: []),
            Dream.DesignSample(prompt: "做汇报 ppt", score: 0.85, liked: nil, issues: []),
            Dream.DesignSample(prompt: "做路演 ppt", score: 0.5, liked: false, issues: ["P2: 0.4 纯文字无视觉", "P3: 0.5 标题截断"]),
        ]
        // 注入夹带代码的蒸馏输出——必须被剥;经验正文保留。
        let insights = await Dream.consolidateDesignInsights(samples: samples) { _ in
            """
            - 封面用满版图 + 遮罩,评分最高
            - 纯文字页评分最低,要配图标
            ```python
            import os
            ```
            """
        }
        let text = try? XCTUnwrap(insights)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("满版图"))
        XCTAssertFalse(text!.contains("import os"), "红线:设计经验绝不含可执行代码")
        XCTAssertTrue(text!.contains("3 次"), "应注明来自几次评分")
    }
}
