import XCTest
@testable import LingShuMac

/// 通用中枢 P2 真闭环·防伪完成闸 + 能力获取分类(纯逻辑,无模型,通用零领域)。
final class TaskCompletionGateTests: XCTestCase {

    // MARK: 能力获取分类(最小验证)

    func testAcquisitionClassifyTriState() {
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(.init(requiresUser: true)), .needsUser, "需用户类→needsUser")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(.init(requiresUser: false)), .notAttempted, "没试过→notAttempted")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(
            .init(requiresUser: false, attemptedSelfAcquire: true, acquireSucceeded: false)), .failed, "试了没成→failed")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(
            .init(requiresUser: false, attemptedSelfAcquire: true, acquireSucceeded: true, newCapabilityVerified: false)),
            .acquiredUnverified, "补到了但最小验证没过→acquiredUnverified")
        XCTAssertEqual(LingShuCapabilityAcquisition.classify(
            .init(requiresUser: false, attemptedSelfAcquire: true, acquireSucceeded: true, newCapabilityVerified: true)),
            .acquiredVerified, "补到+最小验证过→acquiredVerified")
    }

    func testOnlyAcquiredVerifiedResolvesGap() {
        XCTAssertTrue(LingShuAcquisitionOutcome.acquiredVerified.resolvesGap)
        XCTAssertFalse(LingShuAcquisitionOutcome.acquiredUnverified.resolvesGap, "未验证不算解除")
        XCTAssertFalse(LingShuAcquisitionOutcome.failed.resolvesGap)
        XCTAssertFalse(LingShuAcquisitionOutcome.needsUser.resolvesGap)
    }

    // MARK: 完成闸(spec 第14条通用用例)

    /// 缺 external_system.write(可自补)且还没试 → 进获取流程,不直接完成。
    func testSelfAcquirableGapNotAttemptedDrivesAcquisition() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: false, unresolvedGapSelfAcquirable: true,
            acquisition: .notAttempted))
        XCTAssertEqual(d.status, .needsAcquisition, "可自补但没试→驱动获取,绝不直接完成")
    }

    /// 需用户授权 → waitingForUser。
    func testUserRequiredGapWaitsForUser() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, unresolvedGapSelfAcquirable: false,
            acquisition: .needsUser))
        XCTAssertEqual(d.status, .waitingForUser, "需用户授权/凭据→明确阻断等用户,不伪完成")
    }

    /// 复合任务:A 成功(有成功标准达成)、B 因授权阻断 → partial。
    func testCompoundPartialWhenSomeMetSomeBlocked() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true,
            acquisition: .needsUser, someSuccessCriteriaMet: true))
        XCTAssertEqual(d.status, .partial, "部分完成+部分阻断→partial,不是 completed,也不是纯 waitingForUser")
    }

    /// 回复承认「无法接入/未授权」→ 禁止 verified(无任何达成→blocked)。
    func testAdmitsIncapacityForbidsVerified() {
        let d = LingShuTaskCompletionGate.decide(.init(replyAdmitsIncapacity: true))
        XCTAssertEqual(d.status, .blocked, "承认无能力且无达成→blocked,绝不当完成")
        let d2 = LingShuTaskCompletionGate.decide(.init(replyAdmitsIncapacity: true, someSuccessCriteriaMet: true))
        XCTAssertEqual(d2.status, .partial, "承认无能力但有部分达成→partial")
    }

    /// 成功标准部分达成、部分未达成 → partial。
    func testPartialFromCriteriaSplit() {
        let d = LingShuTaskCompletionGate.decide(.init(someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: true))
        XCTAssertEqual(d.status, .partial)
    }

    /// 无缺口、未承认无能力、未见部分缺失 → ok(交既有验收/收尾流程,不越权)。
    func testCleanGoesOk() {
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init()).status, .ok)
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init(someSuccessCriteriaMet: true)).status, .ok, "全达成无未达成→ok")
    }

    /// 自补缺口已 acquiredVerified → 落回成功标准判,不再阻断。
    func testAcquiredVerifiedFallsThrough() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true,
            acquisition: .acquiredVerified, someSuccessCriteriaMet: true))
        XCTAssertEqual(d.status, .ok, "缺口已补齐+验证过→按成功标准走,不卡")
    }

    /// 尝试补齐但失败/未验证 → 无达成则 blocked、有达成则 partial(诚实,非伪完成)。
    func testAcquireFailedHonestlyBlocksOrPartial() {
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .failed)).status, .blocked)
        XCTAssertEqual(LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true,
            acquisition: .acquiredUnverified, someSuccessCriteriaMet: true)).status, .partial)
    }

    // MARK: 通用承认语检测(非领域)

    func testReplyAdmitsIncapacityGeneric() {
        XCTAssertTrue(LingShuTaskCompletionGate.replyAdmitsIncapacity("结果:无法接入 Notion,我当前没有该 API 接入能力"))
        XCTAssertTrue(LingShuTaskCompletionGate.replyAdmitsIncapacity("未授权,需要你授权后我才能操作"))
        XCTAssertTrue(LingShuTaskCompletionGate.replyAdmitsIncapacity("暂时无法完成这一步"))
        XCTAssertFalse(LingShuTaskCompletionGate.replyAdmitsIncapacity("已完成,文件保存在 /tmp/out.txt"), "正常完成不应误判")
        XCTAssertFalse(
            LingShuTaskCompletionGate.replyAdmitsIncapacity("蓝牙设备 16 个,均未连接;USB/雷电口无任何有线外设;AirPlay 投屏设备 2 个。"),
            "设备发现里的'未连接/无外设'是客观扫描结果,不是灵枢承认无能力"
        )
    }

    @MainActor
    func testQuestionRecordBypassesCompletionGateEvenWhenReplyContainsIncapacityWords() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "什么是 HTTP 第 3 问")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "解释 HTTP", kind: .question), to: rid)

        let reply = "HTTP 是无状态协议,无法直接记住你是谁;如果需要更深入讲 HTTP/3,随时说。"
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "普通问答不应被防伪完成闸误判成任务失败")
    }

    @MainActor
    func testLegacyChatRecordWithoutTaskEvidenceBypassesCompletionGate() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "解释 HTTP")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        let reply = "HTTP 本身不记住会话,所以无法直接保存用户状态。"
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "旧问答记录没有任务证据时也不应触发完成闸")
    }

    // MARK: 状态映射

    func testFinishStatusMapping() {
        XCTAssertEqual(LingShuState.finishStatus(for: .partial, fallback: .completed), .partial)
        XCTAssertEqual(LingShuState.finishStatus(for: .waitingForUser, fallback: .completed), .waitingForUser)
        XCTAssertEqual(LingShuState.finishStatus(for: .blocked, fallback: .completed), .blocked)
        XCTAssertEqual(LingShuState.finishStatus(for: .needsAcquisition, fallback: .completed), .blocked, "驱动到顶仍没补→blocked")
        XCTAssertEqual(LingShuState.finishStatus(for: .ok, fallback: .answered), .answered, "ok→用 fallback")
        XCTAssertEqual(LingShuState.finishStatus(for: nil, fallback: .completed), .completed)
    }

    // MARK: 不泄漏内部停滞文本(修"返回值很怪")

    func testInternalDumpDetection() {
        XCTAssertTrue(LingShuState.looksLikeInternalDump("（我连续 16 步只在读取查看、没能动手产出——这步我判断不清,先停下。最近看到：✓ run_command：（无输出，退出码 0）"))
        XCTAssertTrue(LingShuState.looksLikeInternalDump("（无输出，退出码 0）"))
        XCTAssertTrue(LingShuState.looksLikeInternalDump("反复尝试同一动作未果"))
        XCTAssertFalse(LingShuState.looksLikeInternalDump("已完成,文件在 /tmp/out.txt,含三张图表。"))
    }

    @MainActor
    func testHonestWaitingMessageIsCleanNoStallLeak() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到 Notion")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        state.bindGoalSpec(.init(objective: "把待办同步到 Notion", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .humanConfirmation, missing: "Notion 集成 Token", fillPath: "去 notion.so/my-integrations 创建", blocking: true)
        ], note: ""), to: rid)
        let dump = "（我连续 16 步只在读取查看、没能动手产出——这步我判断不清,先停下。最近看到：✓ run_command：（无输出"
        let out = state.honestDeliveryText(decision: .init(status: .waitingForUser, reason: "需用户"), original: dump, taskRecordID: rid)
        XCTAssertFalse(out.contains("连续"), "不泄漏内部停滞文本")
        XCTAssertFalse(out.contains("无输出"), "不泄漏占位文本")
        XCTAssertTrue(out.contains("Notion 集成 Token"), "干净地说清需要用户给什么")
    }

    @MainActor
    func testUserRequiredGapRendersAuthorizationChoiceBlock() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "扫描当前网络里的无线投屏设备")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "扫描当前网络里的无线投屏设备", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .device,
                  missing: "device.discover:当前网络里的 AirPlay/Chromecast 设备",
                  fillPath: "需要本地网络/设备发现授权后继续探测。",
                  blocking: true)
        ], note: ""), to: rid)

        let block = state.userAuthorizationBlockIfNeeded(
            decision: .init(status: .blocked, reason: "回复中承认无法完成/无能力"),
            result: .completed(text: "这一步需要你授权本地网络/设备发现权限后才能继续扫描 AirPlay/Chromecast 设备。"),
            taskRecordID: rid
        )

        guard case .blocked(let prompt) = block,
              let envelope = LingShuHumanInputEnvelope.decode(from: prompt) else {
            return XCTFail("需用户授权的缺口必须转成可渲染的 human-in-the-loop 卡片")
        }
        XCTAssertEqual(envelope.tool, "ask_choice", "授权/设备确认应弹可点击选择卡,不能只是普通文字")
        let parsed = LingShuState.parseChoiceArgs(envelope.argumentsJSON)
        XCTAssertTrue(parsed.0.contains("AirPlay") || parsed.0.contains("Chromecast") || parsed.0.contains("无线投屏"))
        XCTAssertTrue(parsed.1.contains(where: { $0.label.contains("确认授权") }))
        XCTAssertTrue(parsed.1.contains(where: { $0.label.contains("暂不授权") }))
    }

    @MainActor
    func testDispatchedWaitingBubbleGetsAuthorizationChoices() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部知识库")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.dispatchedTaskBubbles.removeValue(forKey: rid)
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "同步到外部知识库", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "external_system.write:外部知识库",
                  fillPath: "需要用户完成账号授权或提供凭据。",
                  blocking: true)
        ], note: ""), to: rid)
        if let idx = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) {
            state.taskExecutionRecords[idx].status = .waitingForUser
            state.taskExecutionRecords[idx].taskOutcome = .waitingForUser
        }
        let pending = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true, taskRecordID: rid)
        state.chatMessages.append(pending)
        state.dispatchedTaskBubbles[rid] = pending.id

        state.fillDispatchedBubble(rid, text: "这一步需要你对外部知识库完成授权后才能继续。")

        guard let bubble = state.chatMessages.first(where: { $0.id == pending.id }) else {
            return XCTFail("派发气泡应被回填而不是丢失")
        }
        XCTAssertFalse(bubble.isLoading)
        XCTAssertEqual(bubble.awaitingInputForRecordID, rid, "待用户气泡的补充/点击必须直达原任务线程")
        XCTAssertNotNil(bubble.choices, "待用户授权边界必须渲染结构化选择入口,不能只显示普通文字")
        XCTAssertTrue(bubble.choices?.options.contains(where: { $0.label.contains("确认授权") }) ?? false)
    }

    @MainActor
    func testAskUserProtectedBoundaryRendersAuthorizationChoices() throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部知识库")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "同步到外部知识库", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "external_system.write:外部知识库",
                  fillPath: "需要用户完成账号授权或提供凭据。",
                  blocking: true)
        ], note: ""), to: rid)
        let payload = ["question": "需要你对外部知识库授权或提供凭据后,我才能继续同步。"]
        let args = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        let envelope = LingShuHumanInputEnvelope(tool: "ask_user", argumentsJSON: args)
        let pending = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true, taskRecordID: rid)
        state.chatMessages.append(pending)

        let rendered = state.renderHumanInputBlockIfNeeded(
            result: .blocked(question: envelope.encodedPrompt),
            bubbleID: pending.id,
            recordID: rid,
            prompt: "同步到外部知识库",
            startedAt: Date()
        )

        XCTAssertTrue(rendered)
        let bubble = try XCTUnwrap(state.chatMessages.first(where: { $0.id == pending.id }))
        XCTAssertFalse(bubble.isLoading)
        XCTAssertNotNil(bubble.choices, "主动 ask_user 触达受保护边界时也必须升级成结构化授权入口")
        XCTAssertTrue(bubble.choices?.options.contains(where: { $0.label.contains("确认授权") }) ?? false)
    }

    @MainActor
    func testDispatchedAskUserProtectedBoundaryGetsAuthorizationChoices() throws {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部知识库")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.dispatchedTaskBubbles.removeValue(forKey: rid)
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "同步到外部知识库", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "external_system.write:外部知识库",
                  fillPath: "需要用户完成账号授权或提供凭据。",
                  blocking: true)
        ], note: ""), to: rid)
        let pending = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true, taskRecordID: rid)
        state.chatMessages.append(pending)
        state.dispatchedTaskBubbles[rid] = pending.id
        let payload = ["question": "需要你对外部知识库授权或提供凭据后,我才能继续同步。"]
        let args = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        let envelope = LingShuHumanInputEnvelope(tool: "ask_user", argumentsJSON: args)

        state.markDispatchedBubbleAwaitingInput(recordID: rid, question: envelope.encodedPrompt)

        let bubble = try XCTUnwrap(state.chatMessages.first(where: { $0.id == pending.id }))
        XCTAssertEqual(bubble.awaitingInputForRecordID, rid)
        XCTAssertNotNil(bubble.choices, "派发任务主动 ask_user 时也必须给可点击授权入口")
        XCTAssertTrue(bubble.choices?.options.contains(where: { $0.label.contains("确认授权") }) ?? false)
    }

    @MainActor
    func testBogusBareUserAuthorizationReplyDoesNotRenderAuthorizationBlock() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "写 add.py 并测试")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "写 add.py 并测试", kind: .task), to: rid)

        let block = state.userAuthorizationBlockIfNeeded(
            decision: .init(status: .partial, reason: "部分目标已完成;另一部分需用户前提。"),
            result: .completed(text: "已完成 add.py 测试。还需要你对「用户」的授权。"),
            taskRecordID: rid
        )

        XCTAssertNil(block, "没有具体受保护边界的泛化用户授权不能弹授权卡,否则自包含任务又会误卡")
    }

    func testHumanInputEnvelopeIsNeverRenderedRaw() throws {
        let payload: [String: Any] = [
            "question": "请选择下一步",
            "options": [["label": "继续"], ["label": "停止"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let envelope = LingShuHumanInputEnvelope(
            tool: "ask_choice",
            argumentsJSON: String(data: data, encoding: .utf8) ?? "{}"
        )

        let raw = "这条任务需要你定一下:\(envelope.encodedPrompt)"
        let visible = LingShuHumanInputEnvelope.userFacingText(from: raw)

        XCTAssertTrue(visible.contains("请选择下一步"))
        XCTAssertFalse(visible.contains(LingShuHumanInputEnvelope.prefix), "用户可见文本不得露出内部协议前缀")
        XCTAssertFalse(visible.contains("eyJ"), "用户可见文本不得露出 base64 payload")
    }

    @MainActor
    func testBareHumanActorGapDoesNotBlockSelfContainedTask() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "写 add.py 并测试")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "写 add.py 并测试", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .permission, missing: "用户", fillPath: "需要用户授权", blocking: true)
        ], note: ""), to: rid)

        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: "已完成 add.py,测试已通过。")

        XCTAssertEqual(decision.status, .ok, "抽象的'用户'不是可授权边界,不能把自包含任务卡成待用户")
        XCTAssertEqual(state.capabilityUserAsk(taskRecordID: rid), "", "不应生成'对用户授权'这种不可执行提示")
    }

    // MARK: 缺口解除 → 不再无限再问(修"给了 token 仍循环再问")

    func testResolvedGapStopsReAsking() {
        let blocking = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission, missing: "Notion Token", fillPath: "去创建集成", blocking: true)
        ], note: "")
        // 未解除:有阻断 + 需用户 → 完成闸 waitingForUser(会问)。
        XCTAssertTrue(blocking.hasBlockingGap)
        XCTAssertTrue(blocking.blockingNeedsUser)
        // 解除后:不再算阻断 → 完成闸不再据它问。
        var resolved = blocking
        resolved.gaps[0].resolved = true
        XCTAssertFalse(resolved.hasBlockingGap, "解除后无未解除阻断缺口")
        XCTAssertFalse(resolved.blockingNeedsUser)
        XCTAssertTrue(resolved.blockingGaps.isEmpty, "blockingGaps 只算未解除")
    }

    func testGapResolvedCodableBackCompat() throws {
        // 新:带 resolved 往返。
        var g = LingShuGapAnalysis(feasibleNow: false, gaps: [
            .init(kind: .permission, missing: "Token", fillPath: "p", blocking: true)
        ], note: "")
        g.gaps[0].resolved = true
        let back = try JSONDecoder().decode(LingShuGapAnalysis.self, from: JSONEncoder().encode(g))
        XCTAssertTrue(back.gaps[0].resolved, "resolved 随记录持久化")
        // 旧:无 resolved 键 → 解码为 false(向后兼容,不崩)。
        let oldJSON = #"{"feasibleNow":false,"note":"","gaps":[{"kind":"permission","missing":"Token","fillPath":"p","blocking":true}]}"#
        let old = try JSONDecoder().decode(LingShuGapAnalysis.self, from: Data(oldJSON.utf8))
        XCTAssertFalse(old.gaps[0].resolved, "老记录无 resolved 键→false")
        XCTAssertTrue(old.hasBlockingGap, "老阻断缺口仍生效")
    }

    @MainActor
    func testResolveUserProvidedGapsUnblocks() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步 Notion")
        defer { state.taskExecutionRecords.removeAll { $0.id == rid }; state.persistTaskExecutionRecords(); state.taskExecutionJournal.flush() }
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .permission, missing: "Notion Token", fillPath: "创建集成", blocking: true)
        ], note: ""), to: rid)
        if let i = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) { state.taskExecutionRecords[i].taskOutcome = .waitingForUser }
        XCTAssertTrue(state.gapAnalysis(for: rid)?.hasBlockingGap ?? false)
        state.resolveUserProvidedGaps(recordID: rid)
        XCTAssertFalse(state.gapAnalysis(for: rid)?.hasBlockingGap ?? true, "用户回应后阻断缺口解除→不再无限再问")
        XCTAssertNil(state.taskExecutionRecords.first { $0.id == rid }?.taskOutcome, "清旧裁决,据真实结果重判")
    }

    func testPrerequisiteChoiceSemanticsDistinguishesUserIntent() {
        XCTAssertEqual(
            LingShuState.prerequisiteChoiceSemantics(.init(label: "已授权，继续")),
            .provided
        )
        XCTAssertEqual(
            LingShuState.prerequisiteChoiceSemantics(.init(label: "暂不授权")),
            .denyOrStop
        )
        XCTAssertEqual(
            LingShuState.prerequisiteChoiceSemantics(.init(label: "改用替代方案")),
            .alternative
        )
        XCTAssertFalse(LingShuState.userInputProvidesPrerequisite("暂不授权"))
        XCTAssertFalse(LingShuState.userInputProvidesPrerequisite(LingShuState.framedAlternativePrerequisiteInput("改用替代方案")))
        XCTAssertTrue(LingShuState.userInputProvidesPrerequisite("token: abc123"))
    }

    @MainActor
    func testDeniedPrerequisiteClosesRecordWithoutResolvingGapOrHoldingDispatchSlot() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部系统")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.dispatchedTaskBubbles.removeValue(forKey: rid)
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "同步到外部系统", kind: .task), to: rid)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(kind: .permission,
                  missing: "external_system.write:外部系统",
                  fillPath: "需要用户授权或提供凭据。",
                  blocking: true)
        ], note: ""), to: rid)
        if let idx = state.taskExecutionRecords.firstIndex(where: { $0.id == rid }) {
            state.taskExecutionRecords[idx].status = .waitingForUser
            state.taskExecutionRecords[idx].taskOutcome = .waitingForUser
        }
        let pending = ChatMessage(speaker: "灵枢", text: "等待授权", isUser: false, isLoading: true, taskRecordID: rid, awaitingInputForRecordID: rid)
        state.chatMessages.append(pending)
        state.dispatchedTaskBubbles[rid] = pending.id
        state.blockedDispatchedRecordID = rid

        state.closeDispatchedTaskForDeniedPrerequisite(recordID: rid, answer: "暂不授权")

        let record = state.taskExecutionRecords.first { $0.id == rid }
        XCTAssertEqual(record?.status, .waitingForUser, "拒绝/暂停授权后记录应停在可续待用户态")
        XCTAssertTrue(state.gapAnalysis(for: rid)?.hasBlockingGap ?? false, "用户没有提供凭据时不得解除原阻断缺口")
        XCTAssertNil(state.dispatchedTaskBubbles[rid], "等待用户的任务不应继续占执行槽")
        XCTAssertNil(state.blockedDispatchedRecordID)
        let bubble = state.chatMessages.first { $0.id == pending.id }
        XCTAssertFalse(bubble?.isLoading ?? true, "原加载气泡必须被定稿,不能卡死")
        XCTAssertTrue(bubble?.text.contains("停在这里") ?? false)
    }

    func testNewStatusSemantics() {
        XCTAssertTrue(LingShuTaskExecutionStatus.verified.isTerminal)
        XCTAssertTrue(LingShuTaskExecutionStatus.partial.isTerminal)
        XCTAssertFalse(LingShuTaskExecutionStatus.waitingForUser.isTerminal, "待用户是可续中间停,非终态")
        XCTAssertTrue(LingShuTaskExecutionStatus.waitingForUser.isResumableUnfinished)
        XCTAssertTrue(LingShuTaskExecutionStatus.partial.isResumableUnfinished)
        XCTAssertTrue(LingShuTaskExecutionStatus.blocked.isResumableUnfinished)
        XCTAssertFalse(LingShuTaskExecutionStatus.completed.isResumableUnfinished)
    }
}
