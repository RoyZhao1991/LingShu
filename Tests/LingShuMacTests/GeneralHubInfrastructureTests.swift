import XCTest
@testable import LingShuMac

final class GeneralHubInfrastructureTests: XCTestCase {
    func testWorldModelStoresEntitiesEventsAndActiveTasks() {
        let now = Date(timeIntervalSince1970: 10)
        var model = LingShuWorldModel(updatedAt: now)
        model.upsertEntity(.init(id: "user:owner", kind: .user, name: "主人", confidence: 0.9, firstSeenAt: now, lastSeenAt: now))
        model.upsertTask(.init(id: "task:1", title: "准备汇报", phase: .executing, updatedAt: now.addingTimeInterval(1)))
        model.recordEvent(.init(kind: .userInput, source: "text", summary: "开始准备汇报", relatedEntityIDs: ["user:owner"], occurredAt: now.addingTimeInterval(2)))

        XCTAssertEqual(model.entity(id: "user:owner")?.name, "主人")
        XCTAssertEqual(model.entities(kind: .user).count, 1)
        XCTAssertEqual(model.activeTasks().map(\.id), ["task:1"])
        XCTAssertEqual(model.events.count, 1)
    }

    func testCapabilityProbeRegistryRunsMatchingProbeOnly() async {
        struct ServiceProbe: LingShuCapabilityProbe {
            let id = "service-probe"
            let supportedTargetKinds: Set<LingShuProbeTargetKind> = [.service]

            func probe(_ target: LingShuProbeTarget) async -> [LingShuCapabilityProbeObservation] {
                [.init(targetID: target.id, capabilityID: "tts.stream", verb: "speak", description: "流式语音合成", status: .available, confidence: 0.95)]
            }
        }

        let registry = LingShuCapabilityProbeRegistry()
        await registry.register(ServiceProbe())
        let observations = await registry.probe(.init(id: "svc:tts", kind: .service, name: "TTS Gateway"))

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.capabilityID, "tts.stream")
        XCTAssertEqual(observations.first?.status, .available)
    }

    func testEffectVerificationReportDoesNotHallucinateCompletion() {
        let file = LingShuEffectRequirement(id: "r1", kind: .file, description: "PPT 文件已生成")
        let human = LingShuEffectRequirement(id: "r2", kind: .userConfirmation, description: "用户确认可交付")
        let evidence = [
            LingShuEffectEvidence(requirementID: "r1", source: "fs", summary: "文件存在", confidence: 0.95)
        ]

        let report = LingShuEffectVerificationReport.make(requirements: [file, human], evidence: evidence)

        XCTAssertFalse(report.isFullyVerified)
        XCTAssertTrue(report.needsHuman)
        XCTAssertEqual(report.verdicts.first(where: { $0.requirementID == "r1" })?.status, .verified)
        XCTAssertEqual(report.verdicts.first(where: { $0.requirementID == "r2" })?.status, .needsUserConfirmation)
    }

    func testAdaptiveBrainRouterChoosesByCapabilityNotName() {
        let fast = LingShuBrainProfile(
            id: "fast",
            displayName: "快脑",
            capabilities: [.fastChat, .lowCost],
            maxContextTokens: 32_000,
            latencyScore: 0.95,
            reliabilityScore: 0.6,
            costScore: 0.9
        )
        let strong = LingShuBrainProfile(
            id: "strong",
            displayName: "强脑",
            capabilities: [.deepReasoning, .toolCalling, .longContext, .highReliability],
            maxContextTokens: 256_000,
            latencyScore: 0.4,
            reliabilityScore: 0.95,
            costScore: 0.2
        )

        let demand = LingShuBrainTaskDemand(
            requiredCapabilities: [.deepReasoning, .toolCalling],
            preferredCapabilities: [.highReliability],
            risk: .high,
            contextTokens: 80_000
        )
        let decision = LingShuAdaptiveBrainRouter.route(demand: demand, profiles: [fast, strong])

        XCTAssertEqual(decision.selectedBrainID, "strong")
        XCTAssertTrue(decision.canRun)
    }

    func testSafeSelfEvolutionRequiresApprovalForCoreChanges() {
        let proposal = LingShuEvolutionProposal(
            level: .coreModule,
            risk: .low,
            objective: "优化主线程恢复",
            rationale: "多次恢复失败",
            trigger: .init(source: "experience", symptom: "resume failed", repeatedCount: 3),
            touchedAreas: ["Sources/State"],
            validationPlan: ["swift test"],
            rollbackPlan: "回滚分支"
        )

        let normalized = LingShuSafeSelfEvolutionPolicy.normalizedRisk(level: proposal.level, requestedRisk: proposal.risk)
        let decision = LingShuSafeSelfEvolutionPolicy.evaluate(proposal)

        XCTAssertEqual(normalized, .critical)
        XCTAssertFalse(decision.allowedToRun)
        XCTAssertTrue(decision.requiresHumanApproval)
        XCTAssertTrue(decision.requiredApprovals.contains("human_owner"))
        XCTAssertTrue(decision.requiredApprovals.contains("regression_gate"))
    }

    @MainActor
    func testStateWorldModelTracksTaskLifecycle() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "集成测试:世界模型任务生命周期")

        XCTAssertEqual(state.worldModel.tasks.first(where: { $0.id == recordID })?.phase, .planning)
        XCTAssertTrue(state.worldModel.events.contains {
            $0.kind == .task && $0.payload["recordID"] == recordID && $0.summary.contains("创建任务")
        })

        state.appendTaskRecordMessage(recordID, actor: "测试Agent", role: "执行", kind: .agent, text: "正在推进集成接线验证")
        XCTAssertTrue(state.worldModel.events.contains {
            $0.kind == .task && $0.payload["recordID"] == recordID && $0.summary.contains("正在推进集成接线验证")
        })

        state.finishTaskRecord(recordID, status: .verified, summary: "集成接线验证完成")
        XCTAssertEqual(state.worldModel.tasks.first(where: { $0.id == recordID })?.phase, .completed)
        XCTAssertTrue(state.worldModel.events.contains {
            $0.kind == .task && $0.payload["recordID"] == recordID && $0.summary.contains("任务收尾")
        })
    }

    @MainActor
    func testStateCapabilityProbeObservationsFeedCapabilityGraphAndRecords() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "集成测试:外部 API 能力探测")
        let observation = LingShuCapabilityProbeObservation(
            targetID: "target:api",
            capabilityID: "api.call:DemoGateway",
            verb: LingShuCapabilityVerb.apiCall.rawValue,
            description: "DemoGateway API 需要授权后调用",
            status: .requiresAuth,
            confidence: 0.82
        )

        state.bindCapabilityProbeObservations([observation], to: recordID)

        let record = state.taskExecutionRecords.first(where: { $0.id == recordID })
        XCTAssertEqual(record?.capabilityProbeObservations?.first?.capabilityID, "api.call:DemoGateway")

        let graph = state.capabilityGraph()
        let match = graph.match(.init(verb: .apiCall, target: "DemoGateway", detail: "调用外部 API"))
        if case .needsAuth(let entry) = match {
            XCTAssertEqual(entry.permission, .needsAuth)
            XCTAssertEqual(entry.source, "probe:target:api")
        } else {
            XCTFail("能力探测观察应回流成需授权的能力图谱节点")
        }
    }

    func testGeneralProbeTreatsLocalKnowledgeAsAvailableBuiltin() async {
        let probe = LingShuGeneralCapabilityProbe()
        let observations = await probe.probe(.init(
            id: "target:external_system.read:local",
            kind: .service,
            name: "本地知识检索服务",
            metadata: [
                "verb": LingShuCapabilityVerb.externalSystemRead.rawValue,
                "detail": "调用 recall_local 查询本地知识库"
            ]
        ))

        XCTAssertEqual(observations.first?.status, .available)
        XCTAssertEqual(observations.first?.verb, LingShuCapabilityVerb.localFileScan.rawValue)
        XCTAssertEqual(observations.first?.evidence, ["builtin-local-capability"])
    }

    @MainActor
    func testHumanConfirmProbeObservationsDoNotPoisonCapabilityGraph() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "集成测试:交付确认不应污染能力图谱")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        let observation = LingShuCapabilityProbeObservation(
            targetID: "target:human",
            capabilityID: "human.confirm:用户",
            verb: LingShuCapabilityVerb.humanConfirm.rawValue,
            description: "需要用户确认或提供凭据:用户",
            status: .requiresAuth,
            confidence: 0.65
        )

        state.bindCapabilityProbeObservations([observation], to: recordID)

        let record = state.taskExecutionRecords.first(where: { $0.id == recordID })
        XCTAssertEqual(record?.capabilityProbeObservations?.first?.capabilityID, "human.confirm:用户",
                       "历史记录可以保留原始观察,但不能投影成能力")
        XCTAssertFalse(state.capabilityNodes().contains { $0.id == "probe:human.confirm:用户" },
                       "human.confirm 探测观察不应变成能力节点")
        if case .missing = state.capabilityGraph().match(.init(verb: .humanConfirm, target: "用户", detail: "告知结果")) {
            // expected
        } else {
            XCTFail("human.confirm 探测观察不应让图谱返回 needsAuth")
        }
    }

    func testGeneralProbeSkipsHumanConfirmationTargets() async {
        let probe = LingShuGeneralCapabilityProbe()
        let observations = await probe.probe(.init(
            id: "target:human",
            kind: .unknown,
            name: "用户",
            metadata: ["verb": LingShuCapabilityVerb.humanConfirm.rawValue]
        ))

        XCTAssertTrue(observations.isEmpty, "human.confirm 是交互边界,不是可探测能力")
    }

    @MainActor
    func testStateEffectVerificationReportPersistsAndPublishesWorldEvent() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "集成测试:真实效果验收")
        let acceptance = LingShuAcceptanceReport(verdicts: [
            .init(criterion: "生成 report.md", kind: .fileExists, status: .met, evidence: "文件系统已核实存在:report.md"),
            .init(criterion: "用户确认可以交付", kind: .userConfirmation, status: .unverifiable, evidence: "需用户确认")
        ], note: "一项确定性通过,一项等待用户确认")
        let report = state.effectVerificationReport(from: acceptance)

        state.bindEffectVerificationReport(report, to: recordID)

        let record = state.taskExecutionRecords.first(where: { $0.id == recordID })
        XCTAssertEqual(record?.effectVerificationReport?.verdicts.count, 2)
        XCTAssertTrue(record?.effectVerificationReport?.needsHuman == true)
        XCTAssertTrue(state.worldModel.events.contains {
            $0.kind == .verification && $0.payload["recordID"] == recordID && $0.summary.contains("需要用户确认")
        })
    }
}
