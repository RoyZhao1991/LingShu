import XCTest
@testable import LingShuMac

/// 灵枢自检(自我认知):策展架构非空 + 渲染 + 实时能力拼装含当前大脑/工具。
final class SelfInspectionTests: XCTestCase {

    func testArchitectureOverviewCoversCoreLayers() {
        let arch = LingShuSelfInspection.architectureOverview()
        XCTAssertFalse(arch.isEmpty)
        XCTAssertTrue(arch.contains { $0.title.contains("agent 循环") }, "应含 agent 循环骨干层")
        XCTAssertTrue(arch.contains { $0.title.contains("模型网关") }, "应含模型网关层")
        XCTAssertTrue(arch.contains { $0.title.contains("感知") }, "应含感知层")
        XCTAssertTrue(arch.contains { $0.title.contains("记忆") }, "应含记忆层")
        XCTAssertTrue(arch.allSatisfy { !$0.items.isEmpty }, "每层都有要点")
    }

    func testMarkdownRendersBothSections() {
        let insp = LingShuSelfInspection(
            oneLiner: "我是灵枢。",
            architecture: [.init(title: "骨干", items: ["统一循环"])],
            capabilities: [.init(title: "大脑", items: ["GLM"])]
        )
        let md = insp.markdown()
        XCTAssertTrue(md.contains("整体架构"))
        XCTAssertTrue(md.contains("当前能力"))
        XCTAssertTrue(md.contains("骨干") && md.contains("统一循环"))
        XCTAssertTrue(md.contains("大脑") && md.contains("GLM"))
        XCTAssertTrue(insp.brief().contains("骨干"), "精简版含架构分层")
    }

    @MainActor
    func testAssemblePullsLiveBrainAndTools() {
        let state = LingShuState()
        state.language = .chinese
        let insp = state.assembleSelfInspection()
        XCTAssertFalse(insp.architecture.isEmpty, "架构层非空")
        XCTAssertTrue(insp.capabilities.contains { $0.title.contains("大脑") }, "能力含当前大脑")
        XCTAssertTrue(insp.capabilities.contains { $0.title.contains("工具") }, "能力含工具")
        // 自检报告里含当前真实大脑名(实时拼装,不是写死)。
        XCTAssertTrue(state.selfInspectionReport.contains(state.modelProvider),
                      "自检报告应含当前大脑供应商名(实时)")
    }

    @MainActor
    func testSelfInspectionGuidanceGroundsCapabilityQuestions() {
        let state = LingShuState()
        state.language = .chinese
        // 架构/能力/自检类问题 → 注入真实自我认知作引导(grounded)。
        XCTAssertNotNil(state.selfInspectionGuidance(for: "你的整体架构是什么"))
        XCTAssertNotNil(state.selfInspectionGuidance(for: "你能做什么"))
        XCTAssertNotNil(state.selfInspectionGuidance(for: "做个自检"))
        XCTAssertTrue(state.selfInspectionGuidance(for: "你能做什么")?.contains(state.modelProvider) == true,
                      "引导里带真实大脑名,大脑据此 grounded 作答")
        // 普通请求不触发(免每轮注入大段自检)。
        XCTAssertNil(state.selfInspectionGuidance(for: "帮我写个快速排序"))
        XCTAssertNil(state.selfInspectionGuidance(for: "今天天气怎么样"))
    }

    @MainActor
    func testAgentInspectionLineShowsAvailabilitySeparately() {
        let state = LingShuState()
        state.language = .chinese

        var available = LingShuAgentPlugin(
            id: "ok", displayName: "OKAgent", executable: "/bin/echo",
            argsTemplate: ["{{objective}}"], available: true, lastCheckedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(state.agentInspectionLine(available).contains("可用"))

        available.available = false
        available.unavailableReason = "令牌过期"
        let unavailableLine = state.agentInspectionLine(available)
        XCTAssertTrue(unavailableLine.contains("不可用:令牌过期"))
        XCTAssertTrue(unavailableLine.contains("@OKAgent"))

        let unverified = LingShuAgentPlugin(
            id: "unknown", displayName: "UnknownAgent", executable: "/bin/echo",
            argsTemplate: ["{{objective}}"], available: nil
        )
        XCTAssertTrue(state.agentInspectionLine(unverified).contains("未探活"))

        let missing = LingShuAgentPlugin(
            id: "missing", displayName: "MissingAgent", executable: "/no/such/agent",
            argsTemplate: ["{{objective}}"], available: true
        )
        XCTAssertTrue(state.agentInspectionLine(missing).contains("找不到可执行文件"))
    }

    @MainActor
    func testEnglishSelfInspectionUsesConfiguredLanguage() {
        let state = LingShuState()
        state.language = .english

        let inspection = state.assembleSelfInspection()
        XCTAssertTrue(inspection.capabilities.contains { $0.title.contains("Brain") })
        XCTAssertTrue(inspection.capabilities.contains { $0.title.contains("Tools") })
        XCTAssertTrue(state.selfInspectionReport.contains(state.modelProviderDisplay))

        var available = LingShuAgentPlugin(
            id: "ok-en", displayName: "OKAgent", executable: "/bin/echo",
            argsTemplate: ["{{objective}}"], available: true
        )
        XCTAssertTrue(state.agentInspectionLine(available).contains("Available"))

        available.available = false
        available.unavailableReason = "token expired"
        XCTAssertTrue(state.agentInspectionLine(available).contains("Unavailable: token expired"))
    }
}
