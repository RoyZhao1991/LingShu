import XCTest
@testable import LingShuMac

/// 通用中枢 P2 真闭环·能力需求 + 能力图谱(纯逻辑 + State 层动态注册/最小验证/复用 + 续接恢复)。
final class CapabilityGraphTests: XCTestCase {

    // MARK: 能力需求解析(通用动词,零领域)

    func testRequirementParse() {
        let raw = """
        ```json
        [{"verb":"external_system.write","target":"用户的 Notion","detail":"同步待办"},
         {"verb":"local_file.scan","target":"/tmp","detail":"找最大文件"},
         {"verb":"瞎写","target":"x"}]
        ```
        """
        let reqs = LingShuCapabilityRequirementPlanner.parse(raw)
        XCTAssertEqual(reqs.count, 2, "未知 verb 被丢弃")
        XCTAssertEqual(reqs[0].verb, .externalSystemWrite)
        XCTAssertEqual(reqs[1].verb, .localFileScan)
    }

    func testVerbAliases() {
        XCTAssertEqual(LingShuCapabilityVerb.parse("external_system.write"), .externalSystemWrite)
        XCTAssertEqual(LingShuCapabilityVerb.parse("API"), .apiCall)
        XCTAssertEqual(LingShuCapabilityVerb.parse("human"), .humanConfirm)
        XCTAssertEqual(LingShuCapabilityVerb.parse("garbage"), .unknown)
    }

    func testInferVerbFromGenericCapabilityText() {
        XCTAssertEqual(
            LingShuCapabilityVerb.infer(id: "mcp:server.create_page", description: "create or update remote page", source: "mcp"),
            .externalSystemWrite
        )
        XCTAssertEqual(
            LingShuCapabilityVerb.infer(id: "skill:presentation", description: "固化技能·presentation design", source: "skill"),
            .documentGenerate
        )
        XCTAssertEqual(
            LingShuCapabilityVerb.infer(id: "browser.navigate", description: "网页导航与 DOM 操作", source: "builtin"),
            .browserOperate
        )
    }

    func testKernelVerbsSatisfiedByMatch() {
        let g = LingShuCapabilityGraph()
        if case .satisfied = g.match(.init(verb: .localFileScan)) {} else { XCTFail("本机扫文件内核原语即满足") }
        if case .satisfied = g.match(.init(verb: .documentGenerate)) {} else { XCTFail("生成文档内核原语即满足") }
        if case .missing = g.match(.init(verb: .externalSystemWrite)) {} else { XCTFail("空图谱写外部系统=缺失") }
    }

    // MARK: 图谱匹配 + 最小验证写入门(spec 第14条 5/6/7)

    func testMatchSatisfiedNeedsAuthMissing() {
        var g = LingShuCapabilityGraph()
        g.upsert(.init(id: "c1", verb: .externalSystemWrite, description: "Notion 连接器", source: "mcp",
                       online: true, permission: .granted, verified: true))
        if case .satisfied(let e) = g.match(.init(verb: .externalSystemWrite)) { XCTAssertEqual(e.id, "c1") }
        else { XCTFail("已验证可用→satisfied") }

        var g2 = LingShuCapabilityGraph()
        g2.upsert(.init(id: "c2", verb: .externalSystemWrite, description: "需授权的连接器", source: "mcp",
                        online: true, permission: .needsAuth, verified: false))
        if case .needsAuth = g2.match(.init(verb: .externalSystemWrite)) {} else { XCTFail("命中但需授权→needsAuth") }
    }

    func testMinVerifyGatesUsable() {
        var g = LingShuCapabilityGraph()
        // 注册了但**未通过最小验证** → 不可用、match 不算 satisfied。
        g.upsert(.init(id: "x", verb: .apiCall, description: "刚注册未验证", source: "authored",
                       online: true, permission: .granted, verified: false))
        XCTAssertTrue(g.usable.isEmpty, "未验证不进 usable")
        if case .missing = g.match(.init(verb: .apiCall)) {} else { XCTFail("未验证不算满足") }
        // 最小验证通过 → 可用、match satisfied。
        XCTAssertTrue(g.markVerified(id: "x"))
        XCTAssertEqual(g.usable.count, 1)
        if case .satisfied = g.match(.init(verb: .apiCall)) {} else { XCTFail("验证后→satisfied") }
    }

    // MARK: State 层:动态注册(模拟 connector/自编组件)→ 图谱更新 → 最小验证 → 复用

    @MainActor
    func testDynamicRegistrationAndReuseWithMinVerify() {
        let key = "lingshu.capability.acquired"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()

        // 验证失败 → 不写入可用能力(spec 第14条第7)。
        let unusable = state.upsertAcquiredCapability(id: "cap.fail", verb: .apiCall, description: "失败连接器", minVerified: false)
        XCTAssertFalse(unusable, "最小验证失败→不可复用")
        XCTAssertFalse(state.capabilityGraph().usable.contains { $0.id == "cap.fail" }, "不进可用图谱")
        XCTAssertTrue(state.acquiredCapabilitiesContext().isEmpty, "未验证不进复用快照")

        // 动态注册成功 + 最小验证通过 → 图谱更新、可复用(spec 第14条 5/6)。
        let usable = state.upsertAcquiredCapability(id: "cap.ok", verb: .externalSystemWrite, description: "已验证的天气连接器", minVerified: true)
        XCTAssertTrue(usable, "最小验证通过→可复用")
        XCTAssertTrue(state.capabilityGraph().usable.contains { $0.id == "cap.ok" }, "进可用图谱")
        XCTAssertTrue(state.acquiredCapabilitiesContext().contains("已验证的天气连接器"), "进复用快照(下次同类目标复用)")
        // 命中需求:写外部系统现在可满足。
        if case .satisfied = state.capabilityGraph().match(.init(verb: .externalSystemWrite)) {} else {
            XCTFail("已获取并验证→需求命中")
        }
    }

    @MainActor
    func testCapabilityRequirementsMergeIntoGapAnalysis() {
        let key = "lingshu.capability.acquired"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部系统")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        state.bindCapabilityRequirements([
            .init(verb: .externalSystemWrite, target: "远端工作台", detail: "写入外部系统"),
            .init(verb: .browserOperate, target: "网页", detail: "浏览器自动化")
        ], to: rid)

        let gap = state.gapAnalysis(for: rid)
        XCTAssertTrue(gap?.hasBlockingGap == true, "图谱未命中的外部写入能力必须反写为阻断缺口")
        XCTAssertTrue(gap?.gaps.contains(where: { $0.missing.contains("external_system.write") }) == true)
        XCTAssertFalse(gap?.gaps.contains(where: { $0.missing.contains("browser.operate") }) == true,
                       "内核浏览器自动化已入图谱,不应误判缺口")
    }

    // MARK: 续接优先恢复(spec 第14条末)

    func testPickResumeTargetPrefersRecentUnfinished() {
        let now = Date()
        func rec(_ id: String, _ status: LingShuTaskExecutionStatus, _ ago: TimeInterval) -> LingShuTaskExecutionRecord {
            .init(id: id, title: id, prompt: id, status: status, summary: "", participants: [],
                  createdAt: now, updatedAt: now.addingTimeInterval(-ago), messages: [])
        }
        let records = [
            rec("done", .completed, 10),
            rec("old-blocked", .blocked, 100),
            rec("recent-waiting", .waitingForUser, 5),
            rec("answered", .answered, 1)
        ]
        XCTAssertEqual(LingShuState.pickResumeTarget(from: records), "recent-waiting", "优先最近的可续未竟任务")
        XCTAssertNil(LingShuState.pickResumeTarget(from: [rec("d", .completed, 1), rec("a", .answered, 2)]),
                     "全是终态→无续接目标")
    }
}
