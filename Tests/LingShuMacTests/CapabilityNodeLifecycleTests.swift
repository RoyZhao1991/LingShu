import XCTest
@testable import LingShuMac

final class CapabilityNodeLifecycleTests: XCTestCase {
    func testCapabilityNodeRegistryOnlyTreatsVerifiedNodesAsSchedulable() {
        let ready = LingShuCapabilityNode(
            id: "adapter:ready",
            name: "已验证适配器",
            kind: .generatedAdapter,
            verb: .apiCall,
            requiredPermissions: [.network],
            source: "test",
            status: .verified,
            lastVerifiedAt: Date(timeIntervalSince1970: 1),
            description: "可真实调用的测试适配器"
        )
        let blocked = LingShuCapabilityNode(
            id: "adapter:blocked",
            name: "待授权适配器",
            kind: .generatedAdapter,
            verb: .apiCall,
            requiredPermissions: [.externalAccount],
            source: "test",
            status: .needsAuth,
            description: "需要授权的测试适配器"
        )

        let report = LingShuCapabilityLifecycleReport(nodes: [ready, blocked], events: [])

        XCTAssertEqual(report.schedulableNodes.map(\.id), ["adapter:ready"])
        XCTAssertEqual(report.blockedNodes.map(\.id), ["adapter:blocked"])
    }

    func testCapabilityNodeProjectionFeedsCapabilityGraphWithLifecycleState() {
        let node = LingShuCapabilityNode(
            id: "external:notion",
            name: "外部系统写入",
            kind: .generatedAdapter,
            verb: .externalSystemWrite,
            requiredPermissions: [.externalAccount],
            source: "probe",
            status: .needsAuth,
            description: "外部系统写入能力需要授权"
        )

        let entry = LingShuCapabilityNodeRegistry.graphEntry(from: node)

        XCTAssertEqual(entry?.id, "external:notion")
        XCTAssertEqual(entry?.verb, .externalSystemWrite)
        XCTAssertEqual(entry?.permission, .needsAuth)
        XCTAssertFalse(entry?.usable == true)

        var graph = LingShuCapabilityGraph()
        graph.upsert(entry!)
        if case .needsAuth(let hit) = graph.match(.init(verb: .externalSystemWrite, target: "外部系统", detail: "同步数据")) {
            XCTAssertEqual(hit.id, "external:notion")
        } else {
            XCTFail("待授权节点应进入图谱,并被判定为需要授权而不是缺失或已满足")
        }
    }

    func testBuiltinMemoryNodeDoesNotSatisfyExternalSystemRead() {
        let nodes = LingShuState.builtinCapabilityNodes()
        let memory = nodes.first { $0.id == "kernel:memory.recall" }
        let entries = nodes.compactMap { LingShuCapabilityNodeRegistry.graphEntry(from: $0) }

        XCTAssertNotNil(memory)
        XCTAssertNil(memory?.verb)
        XCTAssertFalse(entries.contains { $0.verb == .externalSystemRead })
    }

    @MainActor
    func testStatePublishesCapabilityNodesIntoGraphAndWorldModel() {
        let state = LingShuState()

        let nodes = state.capabilityNodes()
        XCTAssertTrue(nodes.contains { $0.id == "kernel:document.generate" && $0.isSchedulable })
        XCTAssertTrue(nodes.contains { $0.id == "kernel:computer.control" && !$0.isSchedulable })

        let graph = state.capabilityGraph()
        if case .satisfied(let entry) = graph.match(.init(verb: .browserOperate, target: "网页", detail: "打开并读取页面")) {
            XCTAssertEqual(entry.verb, .browserOperate)
        } else {
            XCTFail("内置浏览器能力应从能力节点投影到能力图谱")
        }

        let worldEntity = state.worldModel.entity(id: "capability:kernel:document.generate")
        XCTAssertEqual(worldEntity?.attributes["status"], LingShuCapabilityNodeStatus.verified.rawValue)
        XCTAssertEqual(worldEntity?.attributes["schedulable"], "true")
    }

    @MainActor
    func testProbeObservationCreatesBlockedCapabilityNodeAndWorldEntity() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "测试:外部系统授权缺口")
        let observation = LingShuCapabilityProbeObservation(
            targetID: "target:external",
            capabilityID: "external.write:workspace",
            verb: LingShuCapabilityVerb.externalSystemWrite.rawValue,
            description: "外部工作区写入需要授权",
            status: .requiresAuth,
            confidence: 0.8
        )

        state.bindCapabilityProbeObservations([observation], to: recordID)

        let nodes = state.capabilityNodes()
        let node = nodes.first { $0.id == "probe:external.write:workspace" }
        XCTAssertEqual(node?.status, .needsAuth)
        XCTAssertFalse(node?.isSchedulable == true)

        let entity = state.worldModel.entity(id: "capability:probe:external.write:workspace")
        XCTAssertEqual(entity?.attributes["status"], LingShuCapabilityNodeStatus.needsAuth.rawValue)
    }
}
