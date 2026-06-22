import XCTest
@testable import LingShuMac

/// 差距6·命名角色 DAG 拓扑分层纯逻辑守卫:线性链 / 并行层 / 钻石 / 环 / 未知依赖 / 重名 / 解析。
final class AgentDAGTests: XCTestCase {

    private func S(_ name: String, deps: [String] = [], role: String = "r", obj: String = "o") -> LingShuRoleAgentSpec {
        .init(name: name, role: role, objective: obj, dependsOn: deps)
    }
    private func layerNames(_ r: Result<[[LingShuRoleAgentSpec]], LingShuAgentDAG.Failure>) -> [[String]]? {
        if case .success(let layers) = r { return layers.map { $0.map(\.name) } }
        return nil
    }

    func testLinearChain() {
        // A → B → C:三层,各一个。
        let r = LingShuAgentDAG.topologicalLayers([S("A"), S("B", deps: ["A"]), S("C", deps: ["B"])])
        XCTAssertEqual(layerNames(r), [["A"], ["B"], ["C"]])
    }

    func testParallelFirstLayer() {
        // A、B 无依赖(并行),C 依赖两者 → [[A,B],[C]]。
        let r = LingShuAgentDAG.topologicalLayers([S("研究A"), S("研究B"), S("汇总C", deps: ["研究A", "研究B"])])
        XCTAssertEqual(layerNames(r), [["研究A", "研究B"], ["汇总C"]])
    }

    func testDiamond() {
        // A → B,A → C,B&C → D:[[A],[B,C],[D]]。
        let r = LingShuAgentDAG.topologicalLayers([S("A"), S("B", deps: ["A"]), S("C", deps: ["A"]), S("D", deps: ["B", "C"])])
        XCTAssertEqual(layerNames(r), [["A"], ["B", "C"], ["D"]])
    }

    func testCycleDetected() {
        let r = LingShuAgentDAG.topologicalLayers([S("A", deps: ["B"]), S("B", deps: ["A"])])
        guard case .failure(.cycle(let names)) = r else { return XCTFail("应检测到环") }
        XCTAssertEqual(Set(names), ["A", "B"])
    }

    func testSelfDependencyIsCycle() {
        let r = LingShuAgentDAG.topologicalLayers([S("A", deps: ["A"])])
        guard case .failure(.cycle) = r else { return XCTFail("自依赖应判环") }
    }

    func testUnknownDependency() {
        let r = LingShuAgentDAG.topologicalLayers([S("A", deps: ["幽灵"])])
        XCTAssertEqual(r, .failure(.unknownDependency(agent: "A", dep: "幽灵")))
    }

    func testDuplicateName() {
        let r = LingShuAgentDAG.topologicalLayers([S("A"), S("A")])
        XCTAssertEqual(r, .failure(.duplicateName("A")))
    }

    func testEmptyTeam() {
        XCTAssertEqual(LingShuAgentDAG.topologicalLayers([]), .failure(.emptyTeam))
    }

    func testParseEnvelopeWithAliases() {
        let json = """
        {"agents":[
          {"name":"研究员","role":"调研","objective":"调研竞品"},
          {"name":"执行","goal":"实现方案","depends_on":["研究员"]},
          {"name":"审查","task":"审查实现","deps":["执行"]}
        ]}
        """
        let specs = LingShuAgentDAG.parse(json)
        XCTAssertEqual(specs?.count, 3)
        XCTAssertEqual(specs?[1].dependsOn, ["研究员"])
        XCTAssertEqual(specs?[2].dependsOn, ["执行"])
        XCTAssertEqual(specs?[0].objective, "调研竞品")
        // 端到端:解析 → 分层。
        let r = LingShuAgentDAG.topologicalLayers(specs ?? [])
        XCTAssertEqual(layerNames(r), [["研究员"], ["执行"], ["审查"]])
    }

    func testParseRejectsNonTeam() {
        XCTAssertNil(LingShuAgentDAG.parse("not json"))
        XCTAssertNil(LingShuAgentDAG.parse("{\"foo\":1}"))
    }
}
