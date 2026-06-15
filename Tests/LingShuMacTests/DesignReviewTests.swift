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

    func testImageJudgedIrrelevant() {
        XCTAssertTrue(LingShuState.imageJudgedIrrelevant("score=0.8\nissue=OK\nrelevant=no"))
        XCTAssertTrue(LingShuState.imageJudgedIrrelevant("这页配图不相关,是一张风景照"))
        XCTAssertFalse(LingShuState.imageJudgedIrrelevant("score=0.8\nissue=OK\nrelevant=yes"), "相关不应判跑题")
        XCTAssertFalse(LingShuState.imageJudgedIrrelevant("score=0.8\nissue=OK\nrelevant=na"), "无配图(na)不算跑题")
        XCTAssertFalse(LingShuState.imageJudgedIrrelevant("排版整洁,配图切题"), "正常描述不应误判")
    }

    // MARK: Phase C — 设计经验自进化(从评分提炼,红线净化)

    func testUserFeedbackConsolidatesWithSingleSample() async {
        // 用户反馈是高信号:minSamples=1 即可固化;反馈点必须进蒸馏提示(下次 PPT 遵守)。
        let samples = [
            Dream.DesignSample(prompt: "做电池科普 ppt", score: 0.8, liked: nil,
                               issues: ["用户反馈: 深色底上黑色图标看不清", "用户反馈: 配图是无关的笔记本电脑"])
        ]
        // 蒸馏闭包回显收到的提示,据此断言用户反馈点确实进了提示(再返回固化要点)。
        let insights = await Dream.consolidateDesignInsights(samples: samples, minSamples: 1) { prompt in
            XCTAssertTrue(prompt.contains("用户反馈"), "蒸馏提示应纳入用户反馈点")
            XCTAssertTrue(prompt.contains("黑色图标看不清") || prompt.contains("无关的笔记本"), "具体反馈应在提示里")
            return "- 深色主题图标一律用亮色,禁用近黑色\n- 配图必须切题,抽象主题宁用图标不配照片"
        }
        XCTAssertNotNil(insights, "单条用户反馈也应能固化")
        XCTAssertTrue(insights!.contains("亮色"))
    }

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
