import XCTest
@testable import LingShuMac

final class ChecklistVerdictTests: XCTestCase {
    func testAllPassedRequiresDeclarationAndNoFailures() {
        let v = LingShuChecklistVerdict.parse("""
        ✅ 标准一：已覆盖
        ✅ 标准二：图表完整
        结论：通过
        """)
        XCTAssertTrue(v.allPassed)
        XCTAssertEqual(v.passedCount, 2)
        XCTAssertEqual(v.failedCount, 0)
    }

    func testAnyFailureBlocksPass() {
        let v = LingShuChecklistVerdict.parse("""
        ✅ 标准一：已覆盖
        ❌ 标准二：缺少验收口径，需补充
        结论：需修正
        """)
        XCTAssertFalse(v.allPassed)
        XCTAssertEqual(v.failedCount, 1)
    }

    func testDeclaredPassButHasFailureLineIsNotPassed() {
        // 容错：嘴上说通过但有 ❌ 行 → 不算过，避免"假完成"
        let v = LingShuChecklistVerdict.parse("""
        ❌ 标准一：没达标
        结论：通过
        """)
        XCTAssertFalse(v.allPassed)
    }

    func testNoDeclarationIsNotPassed() {
        let v = LingShuChecklistVerdict.parse("✅ 看起来不错")
        XCTAssertFalse(v.allPassed, "没有明确结论不能算通过")
    }
}

final class ExperienceRuleTests: XCTestCase {
    private func makeService() -> LingShuMemoryService {
        let defaults = UserDefaults(suiteName: "lingshu-exp-\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lingshu-exp-\(UUID().uuidString)", isDirectory: true)
        return LingShuMemoryService(repository: LingShuMemoryRepository(defaults: defaults), semanticStore: LingShuSemanticMemoryStore(directory: dir))
    }

    func testRememberAndRecallExperienceRule() {
        let service = makeService()
        service.rememberExperienceRule(domain: "架构师专家", rule: "技术选型必须给出至少一个被否方案及否决理由", source: "任务评审提炼")
        let rules = service.recallExperienceRules(for: "做一个微服务架构技术选型")
        XCTAssertFalse(rules.isEmpty, "同领域规则应能召回")
        XCTAssertTrue(rules.first?.contains("被否方案") == true)
        XCTAssertEqual(service.experienceRuleCount, 1)
    }

    func testShortRuleRejected() {
        let service = makeService()
        service.rememberExperienceRule(domain: "x", rule: "好", source: "t")
        XCTAssertEqual(service.experienceRuleCount, 0, "过短的规则不入库")
    }
}

final class SkillLoaderTests: XCTestCase {
    func testParseSkillWithFrontmatterAndSections() {
        let md = """
        ---
        id: legal-reviewer
        title: 法务审查专家
        mission: 审查合同条款的法律风险
        triggers: 合同, 法务, 协议
        ---
        ## 专业要点
        - 每条风险点标注严重度
        - 高风险条款必须给修改建议
        ## 交付物模板
        # 法务审查：{合同名}
        ## 一、高风险条款
        ## 评审清单
        - 是否覆盖所有高风险条款
        """
        let skill = LingShuSkillLoader.parse(md, fallbackID: "fallback")
        let unwrapped = try! XCTUnwrap(skill)
        XCTAssertEqual(unwrapped.profile.title, "法务审查专家")
        XCTAssertEqual(unwrapped.profile.id, "skill-legal-reviewer")
        XCTAssertEqual(unwrapped.triggers, ["合同", "法务", "协议"])
        XCTAssertEqual(unwrapped.profile.knowledgeHighlights.count, 2)
        XCTAssertTrue(unwrapped.profile.deliverableTemplate.contains("法务审查"))
        XCTAssertEqual(unwrapped.profile.reviewChecklist.count, 1)
    }

    func testSkillWithoutTitleRejected() {
        XCTAssertNil(LingShuSkillLoader.parse("没有 frontmatter 的正文", fallbackID: "x"))
    }

    func testCompositeRegistryPrefersUserSkillOnTriggerMatch() {
        let userSkill = LingShuSkillLoader.LoadedSkill(
            profile: .init(id: "skill-legal", title: "法务审查专家", mission: "x", knowledgeHighlights: [], deliverableTemplate: "t", reviewChecklist: ["c"]),
            triggers: ["合同"]
        )
        let registry = LingShuCompositeExpertRegistry(userSkills: [userSkill])
        XCTAssertEqual(registry.profile(for: "帮我审一份采购合同").id, "skill-legal", "触发词命中应优先用户技能")
        // PPT 任务：没有用户 skill 时，自动引入策展 PPT skill（Phase 1 自进化），而不是通用内置专家。
        XCTAssertEqual(registry.profile(for: "做一个介绍杭州的PPT").id, "skill-curated-ppt", "PPT 任务自动用策展 skill")
        // 既不命中用户、也不命中策展库 → 回退内置出厂专家。
        XCTAssertTrue(registry.profile(for: "帮我做需求分析").id.hasPrefix("expert-"), "无任何 skill 命中时回退内置")
        XCTAssertEqual(registry.reviewerProfile().id, "expert-reviewer", "评审官固定内置")
    }
}

@MainActor
final class ConnectorRegistryTests: XCTestCase {
    private func makeRegistry() -> LingShuConnectorRegistry {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lingshu-conn-\(UUID().uuidString)", isDirectory: true)
        return LingShuConnectorRegistry(directory: dir)
    }

    func testAddRemoveAndPersist() {
        let registry = makeRegistry()
        registry.addServer(name: "fs", command: "npx", arguments: ["-y", "server-filesystem"])
        XCTAssertEqual(registry.servers.count, 1)
        XCTAssertEqual(registry.servers.first?.command, "npx")
        let id = registry.servers.first!.id
        registry.setEnabled(id: id, enabled: false)
        XCTAssertFalse(registry.servers.first!.enabled)
        registry.removeServer(id: id)
        XCTAssertTrue(registry.servers.isEmpty)
    }

    func testMCPTextExtraction() {
        let result = LingShuMCPClient.extractText(from: [
            "content": [["type": "text", "text": "第一段"], ["type": "image"], ["type": "text", "text": "第二段"]]
        ])
        XCTAssertEqual(result, "第一段\n第二段")
    }
}
