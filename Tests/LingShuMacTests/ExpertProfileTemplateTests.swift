import XCTest
@testable import LingShuMac

final class ExpertProfileTemplateTests: XCTestCase {
    func testBuiltinEngineerTemplateRendersCurrentTaskName() {
        let prompt = LingShuExpertProfileRegistry.engineer.promptBlock(for: "生成一个灵枢的 Icon")

        XCTAssertTrue(prompt.contains("# 工程交付：生成一个灵枢的 Icon"))
        XCTAssertFalse(prompt.contains("{任务名}"))
    }

    func testLoadedSkillTemplateRendersCommonPlaceholders() throws {
        let markdown = """
        ---
        id: legal-reviewer
        title: 法务审查专家
        mission: 审查合同条款
        triggers: 合同
        ---
        ## 专业要点
        - 标注风险等级
        ## 交付物模板
        # 法务审查：{合同名}
        ## 一、高风险条款
        """
        let skill = try XCTUnwrap(LingShuSkillLoader.parse(markdown, fallbackID: "fallback"))
        let prompt = skill.profile.promptBlock(for: "采购框架协议")

        XCTAssertTrue(prompt.contains("# 法务审查：采购框架协议"))
        XCTAssertFalse(prompt.contains("{合同名}"))
    }
}
