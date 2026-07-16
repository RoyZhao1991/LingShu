import XCTest
@testable import LingShuMac

private final class HumanInteractionScriptedModel: LingShuAgentModel, @unchecked Sendable {
    private var script: [LingShuAgentModelResponse]
    private(set) var snapshots: [[LingShuAgentMessage]] = []

    init(_ script: [LingShuAgentModelResponse]) {
        self.script = script
    }

    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
        snapshots.append(messages)
        return script.isEmpty ? .text("脚本耗尽") : script.removeFirst()
    }
}

final class HumanInteractionControlTests: XCTestCase {
    fileprivate static let interactionJSON = #"""
    {
      "reply": "请在弹出的窗口中扫码，完成后我会继续。",
      "completion": {"status": "waiting_for_user", "reason": "等待扫码", "needs_user": true},
      "user_input": null,
      "human_interaction": {
        "kind": "qr_code",
        "title": "扫码登录",
        "prompt": "请扫描二维码完成登录",
        "payload": {"image_path": "/tmp/login.png"},
        "options": [],
        "completion_probe": {"kind": "http_status", "target": "http://127.0.0.1:9000/health", "expected_status": 200},
        "resume_token": null,
        "source": "worker"
      },
      "inability": null,
      "OAuth": null
    }
    """#

    fileprivate static let completionJSON = #"""
    {
      "reply": "登录完成，任务已继续并交付。",
      "completion": {"status": "ok", "reason": "完成", "needs_user": false},
      "user_input": null,
      "human_interaction": null,
      "inability": null,
      "OAuth": null
    }
    """#

    func testWorkflowControlEnvelopeRoundTripsAndCanBeEmbedded() {
        let request = LingShuHumanInteractionRequest(
            id: "human-1",
            kind: .physicalAction,
            title: "连接设备",
            prompt: "请接通测试设备",
            payload: ["port": "USB-C"],
            source: "tool"
        )
        let envelope = LingShuWorkflowControlEnvelope(event: .requiresHumanInteraction(request))

        XCTAssertEqual(LingShuWorkflowControlEnvelope.decode(from: envelope.encodedPrompt)?.humanInteraction, request)
        XCTAssertEqual(
            LingShuWorkflowControlEnvelope.extract(from: "准备暂停\n\(envelope.encodedPrompt)\n等待恢复")?.humanInteraction,
            request
        )
        XCTAssertEqual(envelope.userFacingText, "请接通测试设备")
    }

    func testStructuredModelOutputParsesGenericHumanInteractionWithoutOAuth() {
        let parsed = LingShuStructuredModelOutput.parse(Self.interactionJSON)

        XCTAssertEqual(parsed?.humanInteraction?.kind, .qrCode)
        XCTAssertEqual(parsed?.humanInteraction?.completionProbe?.kind, .httpStatus)
        XCTAssertTrue(parsed?.declaresUserBlock == true)
        XCTAssertNil(parsed?.OAuth, "通用人机交互不能伪造授权卡")
    }

    func testFinalHumanInteractionPausesAndResumesSameSession() async {
        let model = HumanInteractionScriptedModel([.text(Self.interactionJSON), .text(Self.completionJSON)])
        let session = LingShuAgentSession(id: "human-final", tools: [], model: model)

        let first = await session.send("启动需要扫码的流程")
        guard case .blocked(let prompt) = first,
              let request = LingShuWorkflowControlEnvelope.decode(from: prompt)?.humanInteraction else {
            return XCTFail("结构化 human_interaction 应暂停会话")
        }
        XCTAssertEqual(request.prompt, "请扫描二维码完成登录")
        let blockedBeforeResume = await session.isBlocked
        XCTAssertTrue(blockedBeforeResume)

        let resumed = await session.resume("我已扫码")
        guard case .completed(let raw) = resumed else { return XCTFail("完成交互后应续跑同一会话") }
        XCTAssertEqual(LingShuStructuredModelOutput.parse(raw)?.visibleText, "登录完成，任务已继续并交付。")
        XCTAssertTrue(model.snapshots.last?.contains(where: { $0.role == .user && $0.content == "我已扫码" }) == true)
        let blockedAfterResume = await session.isBlocked
        XCTAssertFalse(blockedAfterResume)
    }

    func testToolMayRequestHumanInteractionWithoutBeingHardCodedAsBlockingTool() async {
        let request = LingShuHumanInteractionRequest(
            kind: .fileSelection,
            title: "选择源文件",
            prompt: "请选择要导入的文件",
            source: "import_tool"
        )
        let control = LingShuWorkflowControlEnvelope(event: .requiresHumanInteraction(request)).encodedPrompt
        let model = HumanInteractionScriptedModel([
            .toolCalls([.init(id: "pick-1", name: "prepare_import", argumentsJSON: "{}")]),
            .text(Self.completionJSON)
        ])
        let tool = LingShuAgentTool(name: "prepare_import", description: "准备导入") { _ in control }
        let session = LingShuAgentSession(id: "human-tool", tools: [tool], model: model)

        let first = await session.send("导入文件")
        guard case .blocked(let prompt) = first else { return XCTFail("工具控制事件应暂停会话") }
        XCTAssertEqual(LingShuWorkflowControlEnvelope.decode(from: prompt)?.humanInteraction?.kind, .fileSelection)

        let resumed = await session.resume("/tmp/source.csv")
        guard case .completed(let raw) = resumed else { return XCTFail("工具交互完成后应续跑") }
        XCTAssertEqual(LingShuStructuredModelOutput.parse(raw)?.completion?.status, .ok)
        let invocations = await session.toolInvocations
        XCTAssertEqual(invocations, ["prepare_import"])
    }

    func testPlainProseAboutQRCodeOrOAuthDoesNotTriggerControlFlow() async {
        let prose = "OAuth 登录常见做法是显示二维码供用户扫码，这里只是解释概念。"
        let session = LingShuAgentSession(
            id: "human-prose",
            tools: [],
            model: HumanInteractionScriptedModel([.text(prose)])
        )

        let result = await session.send("解释扫码登录")
        XCTAssertEqual(result, .completed(text: prose))
    }

    func testCheckerHumanInteractionIsThirdOutcomeNotFailure() {
        let raw = #"""
        {
          "status": "needs_human_interaction",
          "passed": null,
          "summary": "验收需要观察真实设备状态",
          "checks": [],
          "blockingIssues": [],
          "evidence": [],
          "needsUser": null,
          "human_interaction": {
            "kind": "physical_action",
            "title": "连接设备",
            "prompt": "请连接设备并按下测试键",
            "payload": {},
            "options": [],
            "completion_probe": null,
            "resume_token": null,
            "source": "checker"
          }
        }
        """#

        let verdict = LingShuCheckerVerdict.parse(raw)
        XCTAssertEqual(verdict?.outcome, .needsHumanInteraction)
        XCTAssertTrue(verdict?.renderedSummary.hasPrefix("⏸ 等待人机协作") == true)
        XCTAssertFalse(verdict?.renderedSummary.contains("验收未通过") == true)
        XCTAssertFalse(LingShuState.checkerVerdictPassed(raw))
    }

    func testVerificationResumeTokenRoundTrips() {
        let token = LingShuVerificationResumeToken(
            id: "verify-1",
            mode: .checkerSession,
            recordID: "record-1",
            scope: "internal"
        )
        XCTAssertEqual(LingShuVerificationResumeToken.decode(token.encoded), token)
        XCTAssertNil(LingShuVerificationResumeToken.decode("workflow:not-verification"))
    }

    /// 验收员要求人机协作时，保留的必须是验收员自己的会话。用户结果回到该会话后，
    /// 只缓存新的 checker verdict；执行者结果保持不变，避免错误返工或重跑整个目标。
    @MainActor
    func testVerificationHumanInteractionResumesExactCheckerSession() async {
        let state = LingShuState()
        let model = HumanInteractionScriptedModel([.text(Self.interactionJSON), .text(Self.completionJSON)])
        let checker = LingShuAgentSession(id: "checker-exact", tools: [], model: model)
        let first = await checker.send("验收交付物")
        guard case .blocked(let prompt) = first,
              let request = LingShuWorkflowControlEnvelope.decode(from: prompt)?.humanInteraction else {
            return XCTFail("验收员应在原会话中暂停")
        }

        let retained = state.retainVerificationInteraction(
            request,
            mode: .checkerSession,
            scope: "internal",
            recordID: "record-checker",
            objective: "交付目标",
            makerResult: .completed(text: "执行者原始交付"),
            session: checker
        )
        let outcome = await state.resumeVerificationInteraction(retained, answer: "已完成现场确认")
        guard let outcome,
              case .ready(let recordID, let objective, let makerResult) = outcome else {
            return XCTFail("验收员恢复后应回到验收断点")
        }

        XCTAssertEqual(recordID, "record-checker")
        XCTAssertEqual(objective, "交付目标")
        XCTAssertEqual(makerResult, .completed(text: "执行者原始交付"))
        XCTAssertTrue(model.snapshots.last?.contains(where: {
            $0.role == .user && $0.content.contains("已完成现场确认")
        }) == true)
        let verdict = state.consumeResumedVerificationVerdict(
            recordID: "record-checker",
            mode: .checkerSession,
            scope: "internal"
        )
        XCTAssertEqual(LingShuStructuredModelOutput.parse(verdict ?? "")?.completion?.status, .ok)
        XCTAssertNil(state.consumeResumedVerificationVerdict(
            recordID: "record-checker",
            mode: .checkerSession,
            scope: "internal"
        ), "验收断点结果只能消费一次")
    }

    @MainActor
    func testVerificationRetryAfterChannelInterruptionDoesNotDuplicateHumanAnswer() async {
        let state = LingShuState()
        let model = HumanInteractionScriptedModel([
            .text(Self.interactionJSON),
            .failed(reason: "network temporarily unavailable"),
            .text(Self.completionJSON)
        ])
        let checker = LingShuAgentSession(id: "checker-reconnect", tools: [], model: model, maxTurns: 4)
        let first = await checker.send("验收交付物")
        guard case .blocked(let prompt) = first,
              let request = LingShuWorkflowControlEnvelope.decode(from: prompt)?.humanInteraction else {
            return XCTFail("验收员应先等待人机协作")
        }
        let retained = state.retainVerificationInteraction(
            request,
            mode: .deliveryReview,
            scope: "delivery",
            recordID: "record-reconnect",
            objective: "交付目标",
            makerResult: .completed(text: "执行者原始交付"),
            session: checker
        )

        let interrupted = await state.resumeVerificationInteraction(retained, answer: "已完成现场确认")
        guard let interrupted, case .interrupted = interrupted else { return XCTFail("模型通道故障应保持验收断点") }
        let retried = await state.resumeVerificationInteraction(retained, answer: "已完成现场确认")
        guard let retried, case .ready = retried else { return XCTFail("通道恢复后应续接原模型调用") }

        let deliveredAnswers = model.snapshots.last?.filter {
            $0.role == .user && $0.content.contains("已完成现场确认")
        }.count
        XCTAssertEqual(deliveredAnswers, 1, "重连只能重试模型调用，不能重复写入人工结果")
    }
}

@MainActor
final class DynamicWorkflowTests: XCTestCase {
    func testReadyNodesFollowDependencies() {
        var run = LingShuWorkflowRun(goal: "交付", nodes: [
            .init(id: "research", name: "研究", role: "调研", objective: "研究"),
            .init(id: "build", name: "实现", role: "开发", objective: "实现", dependencies: ["research"])
        ])
        XCTAssertEqual(run.readyNodes.map(\.id), ["research"])

        run.updateNode("research", status: .completed, output: "研究完成")
        XCTAssertEqual(run.readyNodes.map(\.id), ["build"])
    }

    func testGraphMutationIsValidatedAndTransactional() throws {
        var run = LingShuWorkflowRun(goal: "交付", nodes: [
            .init(id: "a", name: "A", role: "规划", objective: "A"),
            .init(id: "b", name: "B", role: "执行", objective: "B", dependencies: ["a"])
        ])
        let original = run
        XCTAssertThrowsError(try run.apply([
            .init(operation: .replaceDependencies, node: nil, nodeID: "a", dependencies: ["b"], reason: "制造环")
        ]))
        XCTAssertEqual(run, original, "非法改图必须整体回滚")

        try run.apply([
            .init(
                operation: .addNode,
                node: .init(id: "review", name: "复核", role: "审查", objective: "复核", dependencies: ["b"]),
                nodeID: nil,
                dependencies: nil,
                reason: "补充验收"
            )
        ])
        XCTAssertEqual(run.revision, 2)
        XCTAssertEqual(run.nodes.last?.id, "review")
        XCTAssertNoThrow(try run.validate())
    }

    func testMixedValidAndMalformedMutationBatchIsRejectedAsAWhole() {
        let json = #"""
        {
          "mutations": [
            {"operation":"add_node","node":{"id":"review","name":"复核","role":"审查","objective":"复核"}},
            {"operation":"invent_unknown_operation","node_id":"review"}
          ]
        }
        """#
        XCTAssertNil(LingShuWorkflowMutation.parseList(json), "改图事务不能静默丢弃非法项后局部生效")
    }

    func testWorkflowResumeTokenRoundTrips() {
        let token = LingShuWorkflowResumeToken(workflowID: "wf-1", nodeID: "node-2", sessionID: "session-3")
        XCTAssertEqual(LingShuWorkflowResumeToken.decode(token.encoded), token)
        XCTAssertNil(LingShuWorkflowResumeToken.decode("not-a-workflow-token"))
    }

    func testWorkflowRunPersistsInTaskRecord() throws {
        var record = LingShuTaskExecutionRecord.create(prompt: "交付一个方案")
        record.workflowRuns = [LingShuWorkflowRun(id: "wf-persist", taskRecordID: record.id, goal: "交付", nodes: [
            .init(id: "write", name: "撰写", role: "执行", objective: "写方案", status: .waitingForHuman,
                  humanInteraction: .init(kind: .confirmation, prompt: "确认标题"), sessionID: "role-write")
        ])]

        let decoded = try JSONDecoder().decode(
            LingShuTaskExecutionRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.workflowRuns, record.workflowRuns)
        XCTAssertEqual(decoded.workflowRuns.first?.waitingInteraction?.prompt, "确认标题")
    }

    func testRuntimeRejectsMutationOfStartedNode() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "动态流程测试")
        let run = LingShuWorkflowRun(id: "wf-running", taskRecordID: recordID, goal: "交付", nodes: [
            .init(id: "active", name: "执行", role: "开发", objective: "实现", status: .running)
        ])
        state.persistWorkflowRun(run, recordID: recordID)

        let result = state.applyWorkflowMutations(
            json: #"{"mutations":[{"operation":"remove_node","node_id":"active"}]}"#,
            workflowID: run.id,
            recordID: recordID
        )

        XCTAssertTrue(result.contains("已经开始"))
        XCTAssertEqual(state.workflowRun(id: run.id, recordID: recordID)?.nodes.count, 1)
    }

    func testTeamWorkflowResumesExactBlockedRole() async {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "登录后继续交付")
        let model = HumanInteractionScriptedModel([
            .text(HumanInteractionControlTests.interactionJSON),
            .text(HumanInteractionControlTests.completionJSON)
        ])
        let initial = await state.runAgentTeam(
            argsJSON: #"{"agents":[{"name":"连接器","role":"接入","objective":"登录并验证服务","depends_on":[]}]}"#,
            recordID: recordID,
            model: model
        )
        guard let request = LingShuWorkflowControlEnvelope.decode(from: initial)?.humanInteraction else {
            return XCTFail("角色工作流应把交互请求带回父流程")
        }
        let runBefore = state.taskExecutionRecords.first(where: { $0.id == recordID })?.workflowRuns.first
        XCTAssertEqual(runBefore?.nodes.first?.status, .waitingForHuman)
        XCTAssertNotNil(request.resumeToken)

        let resumed = await state.resumeWorkflowInteraction(request, recordID: recordID, answer: "已扫码")
        XCTAssertTrue(resumed?.contains("动态依赖协作完成") == true)
        let runAfter = state.workflowRun(id: runBefore?.id ?? "", recordID: recordID)
        XCTAssertEqual(runAfter?.nodes.first?.status, .completed)
        XCTAssertEqual(runAfter?.nodes.first?.attempts, 1, "恢复应续接原角色，不应重新运行整个节点")
    }
}
