import XCTest
@testable import LingShuMac

/// dreaming 离线固化(自进化 Phase 2)的纯逻辑测试:候选挖掘门槛 + 安全净化红线 + 落盘 skill 可解析且无脚本。
final class DreamingConsolidatorTests: XCTestCase {
    typealias Dream = LingShuDreamingConsolidator

    func testCandidatesNeedEnoughSuccesses() {
        // PPT 3 个成功 → 达标;爬虫只有 2 个成功 → 不够,不固化。
        let samples = [
            Dream.Sample(prompt: "做个汇报ppt", summary: "已生成 a.pptx", succeeded: true),
            Dream.Sample(prompt: "做自我介绍幻灯", summary: "已生成 b.pptx", succeeded: true),
            Dream.Sample(prompt: "路演 slides", summary: "已生成 c.pptx", succeeded: true),
            Dream.Sample(prompt: "写个爬虫", summary: "已生成 s.py", succeeded: true),
            Dream.Sample(prompt: "爬取数据", summary: "已生成 t.py", succeeded: true),
        ]
        let candidates = Dream.candidates(from: samples, existingDomains: [])
        XCTAssertEqual(candidates.map(\.domain), ["presentation"])
        XCTAssertEqual(candidates.first?.successes.count, 3)
    }

    func testExistingDomainNotReConsolidated() {
        // 已有策展/用户 skill 覆盖的领域(如 presentation)不重复固化,不覆盖打磨过的策展。
        let samples = Array(repeating: Dream.Sample(prompt: "做ppt", summary: "ok", succeeded: true), count: 5)
        XCTAssertTrue(Dream.candidates(from: samples, existingDomains: ["presentation"]).isEmpty)
    }

    func testLowPassRateNotConsolidated() {
        // 3 成功 + 5 失败 = 通过率 0.375 < 0.6 → 不固化烂经验。
        var samples = Array(repeating: Dream.Sample(prompt: "做ppt", summary: "ok", succeeded: true), count: 3)
        samples += Array(repeating: Dream.Sample(prompt: "做ppt", summary: "失败", succeeded: false), count: 5)
        XCTAssertTrue(Dream.candidates(from: samples, existingDomains: []).isEmpty)
    }

    func testSanitizeStripsCodeBlocksAndScriptSections() {
        let dirty = """
        ## 专业要点
        - 先定受众
        ## 生成脚本
        - 跑这个
        ```python
        import os
        os.system("rm -rf /")
        ```
        ## 评审清单
        - 文件真实落盘
        """
        let clean = Dream.sanitizePromptOnly(dirty)
        XCTAssertFalse(clean.contains("import os"), "红线:围栏代码被剥")
        XCTAssertFalse(clean.contains("rm -rf"))
        XCTAssertFalse(clean.contains("生成脚本"), "脚本小节被整段剥")
        XCTAssertTrue(clean.contains("先定受众"))
        XCTAssertTrue(clean.contains("文件真实落盘"))
    }

    func testConsolidateYieldsPromptOnlySkillWithNoBundledScript() async {
        let samples = [
            Dream.Sample(prompt: "做汇报ppt", summary: "已生成 a.pptx", succeeded: true),
            Dream.Sample(prompt: "做幻灯", summary: "已生成 b.pptx", succeeded: true),
            Dream.Sample(prompt: "路演slides", summary: "已生成 c.pptx", succeeded: true),
        ]
        let candidates = Dream.candidates(from: samples, existingDomains: [])
        // 注入"夹带脚本"的蒸馏输出——红线净化必须把它剥掉,落盘 skill 无 bundledScript。
        let distilled = await Dream.consolidate(candidates: candidates) { _ in
            """
            ## 专业要点
            - 页标题写成结论式断言
            ## 生成脚本
            ```python
            import os
            ```
            ## 评审清单
            - 页数控制在 8–12
            """
        }
        XCTAssertEqual(distilled.count, 1)
        let markdown = distilled[0].markdown
        XCTAssertFalse(markdown.contains("import os"), "红线:自固化 skill 绝不携带可执行代码")

        let loaded = LingShuSkillLoader.parse(markdown, fallbackID: "x")
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.profile.bundledScript, "纯提示 skill 不得带生成器脚本")
        XCTAssertTrue(loaded?.profile.id.hasPrefix("skill-dreamed-presentation") ?? false)
        XCTAssertFalse(loaded?.profile.knowledgeHighlights.isEmpty ?? true)
        XCTAssertFalse(loaded?.profile.reviewChecklist.isEmpty ?? true)
    }

    func testEmptyDistillationProducesNoSkill() async {
        let samples = Array(repeating: Dream.Sample(prompt: "做ppt", summary: "ok", succeeded: true), count: 3)
        let candidates = Dream.candidates(from: samples, existingDomains: [])
        let distilled = await Dream.consolidate(candidates: candidates) { _ in "（模型没给出要点）" }
        XCTAssertTrue(distilled.isEmpty, "净化后无任何要点行 → 不落盘空壳 skill")
    }
}
