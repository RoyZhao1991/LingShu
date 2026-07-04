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

    func testRequirementParseDropsDeliveryHumanConfirmButKeepsRealBoundary() {
        let raw = """
        [
          {"verb":"human.confirm","target":"用户","detail":"告知最终结果与文件路径"},
          {"verb":"human.confirm","target":"用户","detail":"需要用户授权或提供凭据"},
          {"verb":"human.confirm","target":"生产数据删除","detail":"删除前必须用户授权确认"},
          {"verb":"external_system.write","target":"远端工作区","detail":"同步数据"}
        ]
        """
        let reqs = LingShuCapabilityRequirementPlanner.parse(raw)

        XCTAssertFalse(reqs.contains { $0.verb == .humanConfirm && $0.target == "用户" },
                       "告知/回复/交付结果不是需要接入或授权的能力")
        XCTAssertTrue(reqs.contains { $0.verb == .humanConfirm && $0.target == "生产数据删除" },
                      "真实高风险边界仍然必须保留")
        XCTAssertTrue(reqs.contains { $0.verb == .externalSystemWrite })
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

    @MainActor
    func testLocalKnowledgeRequirementNormalizesToBuiltInCapability() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "只调用 recall_local 查 VALFS-7003")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        state.bindCapabilityRequirements([
            .init(verb: .externalSystemRead,
                  target: "本地知识检索服务",
                  detail: "调用 recall_local 工具查询本地知识库")
        ], to: rid)

        let record = state.taskExecutionRecords.first { $0.id == rid }
        XCTAssertEqual(record?.capabilityRequirements?.first?.verb, .localFileScan,
                       "本地知识检索应归一为本机能力,不能进入外部系统授权链")
        XCTAssertNil(state.gapAnalysis(for: rid), "内置本地召回能力不应反写为授权缺口")
    }

    @MainActor
    func testExplicitRuntimeToolSelectionNormalizesSpeculativeExternalRequirement() {
        let state = LingShuState()
        let reqs = state.normalizeCapabilityRequirementsForBuiltIns([
            .init(verb: .externalSystemRead,
                  target: "用户的日历服务",
                  detail: "读取用户日历并建立本机知识索引")
        ], contextText: "调用 index_calendar 工具把我的日历索引进本机知识,把结果一句话告诉我。")

        XCTAssertEqual(reqs.first?.verb, .localFileScan,
                       "用户显式点名已注册运行时工具时,不能再把同一目标推入外部授权链")
        XCTAssertEqual(reqs.first?.target, "index_calendar")
    }

    @MainActor
    func testExplicitGenericToolDoesNotCoverUnrelatedExternalRequirement() {
        let state = LingShuState()
        let reqs = state.normalizeCapabilityRequirementsForBuiltIns([
            .init(verb: .externalSystemWrite,
                  target: "用户的第三方工作区",
                  detail: "写入第三方服务")
        ], contextText: "先用 run_command 检查本机环境,然后同步到第三方工作区。")

        XCTAssertEqual(reqs.first?.verb, .externalSystemWrite,
                       "显式提到通用工具不代表它能覆盖无关第三方系统授权")
        XCTAssertEqual(reqs.first?.target, "用户的第三方工作区")
    }

    @MainActor
    func testBogusLocalKnowledgeProbeObservationDoesNotPoisonGraph() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "历史误探测")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        let observation = LingShuCapabilityProbeObservation(
            targetID: "target:external_system.read:local",
            capabilityID: "external_system.read:本地知识检索服务",
            verb: LingShuCapabilityVerb.externalSystemRead.rawValue,
            description: "外部系统能力需要探测接口/授权/连接器:本地知识检索服务",
            status: .requiresAuth,
            confidence: 0.75
        )

        state.bindCapabilityProbeObservations([observation], to: recordID)

        XCTAssertFalse(state.capabilityNodes().contains { $0.id.contains("本地知识检索服务") },
                       "旧的本地知识 requiresAuth 误探测不能继续投影成待授权能力节点")
        if case .missing = state.capabilityGraph().match(.init(verb: .externalSystemRead, target: "真实外部系统", detail: "读取第三方服务")) {
            // expected
        } else {
            XCTFail("旧本地知识误探测不能让真正外部系统读需求命中 needsAuth")
        }
    }

    @MainActor
    func testBindingDropsDeliveryOnlyHumanConfirmRequirement() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "写脚本并告知结果")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        state.bindCapabilityRequirements([
            .init(verb: .humanConfirm, target: "用户", detail: "告知最终结果与文件路径")
        ], to: rid)

        let record = state.taskExecutionRecords.first(where: { $0.id == rid })
        XCTAssertNil(record?.capabilityRequirements, "交付型用户确认不应持久化为能力需求")
        XCTAssertNil(state.gapAnalysis(for: rid), "交付型用户确认不应反写为缺口")
    }

    @MainActor
    func testProtectedHumanConfirmRequirementBecomesBlockingGap() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "删除生产数据前确认")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        state.bindCapabilityRequirements([
            .init(verb: .humanConfirm, target: "生产数据删除", detail: "删除前必须用户确认")
        ], to: rid)

        let gap = state.gapAnalysis(for: rid)
        XCTAssertTrue(gap?.gaps.contains(where: {
            $0.kind == .humanConfirmation && $0.blocking && $0.missing.contains("human.confirm")
        }) == true, "结构化 human.confirm 指向受保护边界时必须成为阻断确认")
        XCTAssertTrue(gap?.needsUserToUnblock == true)
    }

    @MainActor
    func testGenericHumanConfirmRequirementRemainsAdvisory() {
        let gap = LingShuState.gapFromMissingRequirement(
            .init(verb: .humanConfirm, target: "Python 脚本运行结果", detail: "最终告诉用户结果")
        )

        XCTAssertEqual(gap.kind, .humanConfirmation)
        XCTAssertFalse(gap.blocking, "泛化/交付型 human.confirm 不能卡住自包含任务")
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
