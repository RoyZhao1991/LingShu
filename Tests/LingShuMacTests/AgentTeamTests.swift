import XCTest
@testable import LingShuMac

/// 差距6·命名角色团队运行器:① 早退路径(参数/环/未知依赖/极简模式,不触网)② **DAG 运行时**(脚本模型驱动,确定性验证
/// 依赖按序 + 前序产出真传给后续角色 + 聚合)。
@MainActor
final class AgentTeamTests: XCTestCase {

    func testInvalidArgsReturnsError() async {
        let state = LingShuState()
        let out = await state.runAgentTeam(argsJSON: "not json", recordID: nil, model: state.makeAgentModelAdapter())
        XCTAssertTrue(out.contains("参数无效"), "无效参数应早退报错,不起角色:\(out)")
    }

    func testCycleReturnsScheduleErrorBeforeSpawning() async {
        let state = LingShuState()
        let json = "{\"agents\":[{\"name\":\"A\",\"objective\":\"a\",\"depends_on\":[\"B\"]},{\"name\":\"B\",\"objective\":\"b\",\"depends_on\":[\"A\"]}]}"
        let out = await state.runAgentTeam(argsJSON: json, recordID: nil, model: state.makeAgentModelAdapter())
        XCTAssertTrue(out.contains("无法调度") && out.contains("成环"), "成环应早退:\(out)")
    }

    func testUnknownDependencyEarlyReturn() async {
        let state = LingShuState()
        let json = "{\"agents\":[{\"name\":\"A\",\"objective\":\"a\",\"depends_on\":[\"幽灵\"]}]}"
        let out = await state.runAgentTeam(argsJSON: json, recordID: nil, model: state.makeAgentModelAdapter())
        XCTAssertTrue(out.contains("无法调度") && out.contains("不存在"), "未知依赖应早退:\(out)")
    }

    func testMinimalVoiceModeRefuses() async {
        let state = LingShuState()
        state.isMinimalVoiceMode = true
        let json = "{\"agents\":[{\"name\":\"A\",\"objective\":\"a\"},{\"name\":\"B\",\"objective\":\"b\"}]}"
        let out = await state.runAgentTeam(argsJSON: json, recordID: nil, model: state.makeAgentModelAdapter())
        XCTAssertTrue(out.contains("极简对话模式"), "极简模式不派生角色团队:\(out)")
    }

    func testAggregateFormatListsEachRole() {
        let state = LingShuState()
        let specs = [
            LingShuRoleAgentSpec(name: "研究员", role: "调研", objective: "x", dependsOn: []),
            LingShuRoleAgentSpec(name: "执行", role: "实现", objective: "y", dependsOn: ["研究员"]),
        ]
        let agg = state.aggregateTeamResult(specs: specs, outputs: ["研究员": "调研结论", "执行": "实现完成"])
        XCTAssertTrue(agg.contains("研究员·调研") && agg.contains("调研结论"))
        XCTAssertTrue(agg.contains("执行·实现") && agg.contains("实现完成"))
        XCTAssertTrue(agg.contains("2 个角色"))
    }

    /// 据输入内容应答的脚本模型:每个角色返回确定文本,并记录"执行"角色是否真收到了"研究员"的产出(验证依赖上下文传递)。
    final class RoleScriptedModel: LingShuAgentModel, @unchecked Sendable {
        private(set) var execSawResearch = false
        private(set) var reviewSawImpl = false
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            let input = messages.last(where: { $0.role == .user })?.content ?? ""
            if input.contains("审查") {
                if input.contains("实现完成·dedup") { reviewSawImpl = true }
                return .text("审查通过:实现正确")
            }
            if input.contains("基于调研实现") {
                if input.contains("研究结论·用set最快") { execSawResearch = true }
                return .text("实现完成·dedup.py")
            }
            if input.contains("调研去重方法") { return .text("研究结论·用set最快") }
            return .text("done")
        }
    }

    func testDAGRuntimeRunsInOrderAndPassesDependencyOutput() async {
        // 链:研究员 → 执行(依赖研究员)→ 审查(依赖执行)。确定性验证:依赖产出真被传给下游 + 聚合含三角色。
        let state = LingShuState()
        let model = RoleScriptedModel()
        let json = """
        {"agents":[
          {"name":"研究员","role":"调研","objective":"调研去重方法","depends_on":[]},
          {"name":"执行","role":"实现","objective":"基于调研实现","depends_on":["研究员"]},
          {"name":"审查","role":"审查","objective":"审查实现","depends_on":["执行"]}
        ]}
        """
        let out = await state.runAgentTeam(argsJSON: json, recordID: nil, model: model)

        XCTAssertTrue(model.execSawResearch, "「执行」必须收到「研究员」的产出作为依赖上下文(DAG 传递)")
        XCTAssertTrue(model.reviewSawImpl, "「审查」必须收到「执行」的产出作为依赖上下文")
        XCTAssertTrue(out.contains("研究结论") && out.contains("实现完成") && out.contains("审查通过"), "聚合应含三角色产出:\(out)")
        XCTAssertTrue(out.contains("3 个角色"))
    }
}
