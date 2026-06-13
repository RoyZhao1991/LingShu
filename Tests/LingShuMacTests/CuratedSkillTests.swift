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

    func testCompositeRegistryUsesCuratedWhenNoUserSkill() {
        let registry = LingShuCompositeExpertRegistry(userSkills: [])
        let profile = registry.profile(for: "做一个产品路演 PPT")
        XCTAssertTrue(profile.id.contains("curated-ppt"), "无用户 skill 时,PPT 任务应自动用策展 PPT 专家")
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
