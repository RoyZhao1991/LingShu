import XCTest
@testable import LingShuMac

/// 自进化 Phase 1：策展纯提示 skill 库 + 自动引入(命中领域就顶替通用专家)。
final class CuratedSkillTests: XCTestCase {
    func testPPTTaskAutoSelectsCuratedPresentationSkill() {
        let loaded = LingShuCuratedSkillRegistry.bestSkill(forTask: "帮我做个自我介绍PPT")
        XCTAssertNotNil(loaded, "做PPT应命中策展 PPT skill")
        XCTAssertTrue(loaded!.profile.id.contains("curated-ppt"))
        // 验收清单应是可达的(python-pptx 自检),不该要求 LibreOffice/OCR 那种重证据。
        let checklist = loaded!.profile.reviewChecklist.joined()
        XCTAssertTrue(checklist.contains("8–12") || checklist.contains("len(slides)") || checklist.contains("落盘"))
    }

    func testNonMatchingTaskFallsThrough() {
        XCTAssertNil(LingShuCuratedSkillRegistry.bestSkill(forTask: "今天天气怎么样"))
    }

    func testDevelopmentTaskAutoSelectsEngineeringSkill() {
        let loaded = LingShuCuratedSkillRegistry.bestSkill(forTask: "给我开发一个灵枢")
        XCTAssertNotNil(loaded, "开发类任务应命中策展工程技能")
        XCTAssertTrue(loaded!.profile.id.contains("curated-engineering"))
        // 验收清单必须包含"有测试且全绿"这类完整测试闭环硬约束。
        let checklist = loaded!.profile.reviewChecklist.joined()
        XCTAssertTrue(checklist.contains("测试") && (checklist.contains("全绿") || checklist.contains("冒烟")))
    }

    func testCompositeRegistryUsesCuratedWhenNoUserSkill() {
        let registry = LingShuCompositeExpertRegistry(userSkills: [])
        let profile = registry.profile(for: "做一个产品路演 PPT")
        XCTAssertTrue(profile.id.contains("curated-ppt"), "无用户 skill 时,PPT 任务应自动用策展 PPT 专家")
    }

    func testReloadUserSkillsPicksUpNewlyDroppedSkillWithoutRebuild() throws {
        // 热加载:dreaming 固化/用户新增 .md 落盘后,registry.reloadUserSkills() 免重启即时生效。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lingshu-skill-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let registry = LingShuCompositeExpertRegistry(userSkills: [])
        // 起初没有用户 skill,爬虫任务回退(非用户 skill)。
        XCTAssertFalse(registry.profile(for: "写个爬虫抓数据").id.hasPrefix("skill-dreamed"))

        // 落盘一个自固化纯提示 skill,再热加载。
        let md = LingShuDreamingConsolidator.skillMarkdown(
            domain: "crawler", title: "网页爬虫", triggers: ["爬虫", "抓取"],
            body: "## 专业要点\n- 先看 robots\n## 评审清单\n- 数据真实落盘",
            qualityScore: 0.8, sampleCount: 4
        )
        try md.write(to: dir.appendingPathComponent("dreamed-crawler.md"), atomically: true, encoding: .utf8)
        registry.reloadUserSkills(from: dir)

        let profile = registry.profile(for: "写个爬虫抓数据")
        XCTAssertTrue(profile.id.hasPrefix("skill-dreamed-crawler"), "热加载后新固化 skill 应即时命中,无需重启")
        XCTAssertEqual(registry.userSkillCount, 1)
    }

    func testUserSkillStillBeatsCurated() {
        let userSkill = LingShuSkillLoader.parse("""
        ---
        title: 我的专属PPT法
        triggers: ppt,演示
        ---
        ## 专业要点
        - 我的私货
        """, fallbackID: "mine")!
        let registry = LingShuCompositeExpertRegistry(userSkills: [userSkill])
        let profile = registry.profile(for: "做个PPT")
        XCTAssertEqual(profile.title, "我的专属PPT法", "用户自有 skill 仍优先于策展库")
    }
}
