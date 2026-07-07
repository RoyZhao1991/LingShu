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

    @MainActor
    func testPlainReplyPrerequisiteTextDoesNotRenderAuthorizationCardWithoutOAuthField() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "同步到外部知识库")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "把今天待办同步到外部知识库", kind: .task), to: rid)

        let reply = """
        目前没有找到明确的今天待办清单,也没有任何外部知识库的授权信息。
        下一步需要你告诉我待办来源,并提供外部知识库的登录授权或凭据。
        """
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "普通文本里的缺授权/凭据描述不能驱动流程状态;缺前提必须来自完整 JSON 字段")
        let block = state.userAuthorizationBlockIfNeeded(
            decision: decision,
            result: .completed(text: reply),
            taskRecordID: rid
        )
        XCTAssertNil(block, "授权窗只允许由 GapAnalysis.OAuth 结构字段触发,不能由回复文本关键词触发")
    }

    @MainActor
    func testPlainReplyPrerequisiteTextDoesNotRenderAuthorizationCardWithoutGoalSpec() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "灵枢在岗")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        let reply = "要继续同步到外部知识库,需要你先提供该平台的登录授权或 API Key 凭据。"
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "没有结构化任务证据时,回复文本里的授权词不能把普通记录拉进授权等待")
        XCTAssertNil(state.userAuthorizationBlockIfNeeded(
            decision: decision,
            result: .completed(text: reply),
            taskRecordID: rid
        ))
    }

    @MainActor
    func testStructuredOAuthNullDoesNotRenderAuthorizationCard() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "解释 OAuth 原理")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "一句话解释 OAuth 是什么", kind: .question), to: rid)

        let reply = #"{"reply":"OAuth 是一种授权协议:第三方应用拿到受限访问令牌,不直接接触用户密码。","completion":{"status":"ok","reason":"普通知识问答已回答","needs_user":false},"OAuth":null}"#
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok)
        XCTAssertNil(state.userAuthorizationBlockIfNeeded(
            decision: decision,
            result: .completed(text: reply),
            taskRecordID: rid
        ), "完整 JSON 里 OAuth=null 时,即使 reply 解释 OAuth/token/授权,也绝不弹授权窗")
        XCTAssertEqual(LingShuStructuredModelOutput.visibleText(from: reply), "OAuth 是一种授权协议:第三方应用拿到受限访问令牌,不直接接触用户密码。")
    }

    @MainActor
    func testStructuredOAuthObjectRendersAuthorizationCard() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "连接外部知识库")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "把待办同步到外部知识库", kind: .task), to: rid)

        let reply = #"{"reply":"这一步需要你授权外部知识库后我才能继续。","completion":{"status":"waiting_for_user","reason":"缺少外部知识库授权","needs_user":true},"OAuth":{"required":true,"target":"外部知识库","action":"写入待办","reason":"需要用户授权外部知识库写入权限","question":"是否授权我连接外部知识库并写入待办?","options":[{"label":"确认授权","detail":"允许本次写入"},{"label":"暂不授权","detail":"停止这一步"}]}}"#
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)
        let block = state.userAuthorizationBlockIfNeeded(
            decision: decision,
            result: .completed(text: reply),
            taskRecordID: rid
        )

        guard case .blocked(let prompt) = block,
              let envelope = LingShuHumanInputEnvelope.decode(from: prompt) else {
            return XCTFail("OAuth 结构对象应渲染授权卡")
        }
        XCTAssertEqual(envelope.tool, "ask_choice")
        let parsed = LingShuState.parseChoiceArgs(envelope.argumentsJSON)
        XCTAssertTrue(parsed.0.contains("外部知识库"))
        XCTAssertTrue(parsed.1.contains(where: { $0.label == "确认授权" }))
    }

    @MainActor
    func testPlainReplyRequestingExecutionInputDoesNotBecomeChoiceCard() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "把今天待办同步到外部知识库")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "把今天待办同步到外部知识库", kind: .task), to: rid)

        let reply = """
        好的,我查了一下现状。要同步到外部知识库,我需要知道两件事:
        第一,你的今日待办在哪?
        第二,目标外部知识库是哪个?
        告诉我之后我继续。
        """
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "普通文本缺信息不自动转选择卡;需要等待用户时必须由 ask_user/ask_choice 或结构字段表达")
        let block = state.userAuthorizationBlockIfNeeded(
            decision: decision,
            result: .completed(text: reply),
            taskRecordID: rid
        )
        XCTAssertNil(block)
    }

    @MainActor
    func testExecutionInputTextIsNotCaughtWhenRecordWasNotClassifiedAsTask() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "把今天待办同步到一个尚未授权的外部知识库")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        let reply = """
        我查了你的本机日历和知识索引,目前没有找到任何今天的待办事项或日程安排记录。
        要完成"把待办同步到外部知识库"这件事,我需要你提供两样东西:
        1. 你的待办事项是什么。
        2. 你要同步到哪个外部知识库。
        拿到这两样,我才能真做,而不是假装做完。
        """
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "漏分类记录不能再靠回复关键词拉授权/选择卡;分诊和 ask_user 协议负责等待用户")
        let block = state.userAuthorizationBlockIfNeeded(
            decision: decision,
            result: .completed(text: reply),
            taskRecordID: rid
        )
        XCTAssertNil(block)
    }

    func testPlainCapabilityDescriptionIsNotStructuredPrerequisite() {
        XCTAssertNil(
            LingShuStructuredModelOutput.parse("授权后我可以读取屏幕、操作浏览器和控制本机窗口。"),
            "自然语言描述不再参与授权/前提判定"
        )
    }

    func testPlainDeviceDiscoveryResultIsNotStructuredPrerequisite() {
        XCTAssertNil(
            LingShuStructuredModelOutput.parse("已扫描当前网络,没有找到支持无线投屏的电视或盒子设备。"),
            "客观发现文本不再被关键词误判为能力缺口"
        )
    }

    /// 复合任务:A 成功(成功标准达成)、B 因授权阻断 → partial。
    func testCompoundPartialWhenSomeMetSomeBlocked() {
        let d = LingShuTaskCompletionGate.decide(.init(
            hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true,
            acquisition: .needsUser, someSuccessCriteriaMet: true))
        XCTAssertEqual(d.status, .partial, "部分完成+部分阻断→partial,不是 completed,也不是纯 waitingForUser")
    }

    /// **成功标准全绿推翻投机 gap 的判据(纯函数,2026-06-30,根治"全绿却找用户要授权")**:
    /// 有 met、无 unmet、无结构化未完成声明 → true(实跑层据此清掉误报 gap);任一不满足 → 不清(真缺口/真失败照拦)。
    func testAllCriteriaMetResolvesSpeculativeGap() {
        let f = LingShuTaskCompletionGate.allCriteriaMetResolvesSpeculativeGap
        XCTAssertTrue(f(true, true, false, false), "有标准+全绿+无结构化未完成声明 → 清误报 gap")
        XCTAssertFalse(f(true, true, true, false), "有未达成标准 → 不清(仍 partial)")
        XCTAssertFalse(f(true, true, false, true), "结构化未完成声明 → 不清(仍按真失败拦)")
        XCTAssertFalse(f(false, false, false, false), "没成功标准 → 不清(走默认)")
    }

    /// 只有结构化 completion.status 声明 blocked/partial/waiting 时才影响完成闸。
    func testStructuredCompletionForbidsVerified() {
        let d = LingShuTaskCompletionGate.decide(.init(modelDeclaredBlocked: true))
        XCTAssertEqual(d.status, .blocked, "结构化 blocked 且无达成→blocked,绝不当完成")
        let d2 = LingShuTaskCompletionGate.decide(.init(modelDeclaredBlocked: true, someSuccessCriteriaMet: true))
        XCTAssertEqual(d2.status, .partial, "结构化 blocked 但有部分达成→partial")
    }

    /// 成功标准部分达成、部分未达成 → partial。
    func testPartialFromCriteriaSplit() {
        let d = LingShuTaskCompletionGate.decide(.init(someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: true))
        XCTAssertEqual(d.status, .partial)
    }

    /// 无缺口、无结构化未完成声明、未见部分缺失 → ok(交既有验收/收尾流程,不越权)。
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

    // MARK: 结构化模型输出协议

    func testStructuredModelOutputRequiresWholeJSONObject() {
        let blocked = #"{"reply":"暂时无法完成这一步","completion":{"status":"blocked","reason":"缺少受保护前提"},"OAuth":null}"#
        let parsedBlocked = LingShuStructuredModelOutput.parse(blocked)
        XCTAssertEqual(parsedBlocked?.reply, "暂时无法完成这一步")
        XCTAssertEqual(parsedBlocked?.completion?.status, .blocked)
        XCTAssertTrue(parsedBlocked?.declaresBlocked == true)

        let oauth = #"{"reply":"需要授权后继续","completion":{"status":"waiting_for_user","needs_user":true},"OAuth":{"required":true,"target":"外部系统","action":"连接并写入","reason":"需要用户授权","question":"是否授权继续?","options":[{"label":"授权继续","detail":"允许本次操作"},{"label":"暂不授权","detail":"停止"}]}}"#
        let parsedOAuth = LingShuStructuredModelOutput.parse(oauth)
        XCTAssertTrue(parsedOAuth?.OAuth?.normalized != nil)
        XCTAssertTrue(parsedOAuth?.declaresUserBlock == true)

        XCTAssertNil(LingShuStructuredModelOutput.parse("结果:无法接入,需要你授权后我才能操作"), "自然语言不再驱动流程状态")
        XCTAssertNil(LingShuStructuredModelOutput.parse("前面解释\n{\"completion\":{\"status\":\"blocked\"}}"), "夹在文本里的 JSON 片段不被流程层接受")
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

    /// **反例A回归(2026-07-03 收口)**:纯问答(.question)回复带日常收尾语"请告诉我…继续",
    /// 自然语言收尾语绝不许把百科式回答拖进 waitingForUser/补充信息卡。
    @MainActor
    func testQuestionRecordWithConversationalClosingIsNotHijackedByExecutionInputSignal() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "什么是闭包")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "解释闭包", kind: .question), to: rid)

        let reply = "闭包就是能捕获并携带定义环境变量的函数,常用于回调和状态封装。如果你想深入了解,请告诉我,我可以继续展开。"
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "纯问答的日常收尾语不是执行输入索取,不应进入待用户/被改写成选择卡")
    }

    /// **反例B回归(2026-07-03 收口)**:OAuth/token 科普天然含受保护边界词(token/第三方/登录),
    /// 但纯问答(.question)绝不许被改写成授权卡。
    @MainActor
    func testQuestionRecordAboutOAuthIsNotHijackedByPrerequisiteSignal() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "什么是 OAuth")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "解释 OAuth", kind: .question), to: rid)

        let reply = "OAuth 是一种授权框架:你在第三方应用里点登录,它拿到的只是权限受限的 access token,而不是你的密码。"
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "百科式回答含 token/第三方/登录等词形,不应触发授权等待")
    }

    @MainActor
    func testReplyOnlyTaskWithCriteriaBypassesCompletionDeliveryGate() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "检查当前插件入口,如果确认只回复指定语句")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(
            .init(
                objective: "确认当前运行态插件入口仅保留演示与答疑并只回复指定语句",
                kind: .task,
                boundaries: ["不要创建文件", "不要打开预览", "不要进入交付流程"],
                successCriteria: ["输出内容为指定验收语句"],
                outputMode: .chatReply
            ),
            to: rid
        )

        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: "插件验收通过：仅演示与答疑。")

        XCTAssertEqual(decision.status, .ok, "reply-only task 即使带成功标准,也应按聊天回复收口,不进入交付完成闸")
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

    @MainActor
    func testDispatchedBubbleDisplaysStructuredReplyOnly() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "生成分析报告")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.chatMessages.removeAll { $0.taskRecordID == rid }
            state.dispatchedTaskBubbles.removeValue(forKey: rid)
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        let pending = ChatMessage(speaker: "灵枢", text: "处理中", isUser: false, isLoading: true, taskRecordID: rid)
        state.chatMessages.append(pending)
        state.dispatchedTaskBubbles[rid] = pending.id

        let raw = #"{"reply":"分析报告已生成,保存在 /tmp/report.md。","completion":{"status":"ok","reason":"目标已达成","needs_user":false},"user_input":null,"inability":null,"OAuth":null}"#
        state.fillDispatchedBubble(rid, text: raw)

        let bubble = state.chatMessages.first { $0.id == pending.id }
        XCTAssertEqual(bubble?.text, "分析报告已生成,保存在 /tmp/report.md。")
        XCTAssertFalse(bubble?.text.contains(#""reply""#) ?? true, "气泡只展示 reply,不得泄漏协议 JSON")
    }

    @MainActor
    func testContextualTaskPromptCarriesPriorGoalSpecIntoSubtask() {
        let state = LingShuState()
        let spec = LingShuGoalSpec(
            objective: "延续上一轮股票走势与新闻分析,生成更准确的投资分析报告,并交由 Codex 复核",
            kind: .task,
            constraints: ["延续上一轮主题与对象", "不得把当前短句单独当成新目标"],
            successCriteria: ["报告必须围绕上一轮股票分析主题", "必须包含复核结论"]
        )

        let prompt = state.contextualTaskPrompt(
            rawObjective: "出一份更准确的分析报告",
            userPrompt: "给我出一份更准确的分析报告,你来出报告,让 @Codex 复核你的报告",
            goalSpec: spec
        )

        XCTAssertTrue(prompt.contains("上一轮股票走势"))
        XCTAssertTrue(prompt.contains("原始子目标"))
        XCTAssertTrue(prompt.contains("用户本轮原话"))
        XCTAssertTrue(prompt.contains("Codex"))
        XCTAssertTrue(prompt.contains("成功标准"))
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

    @MainActor
    func testDefaultSuccessStatusUsesStructuredTaskEvidenceNotTextKeywords() {
        let state = LingShuState()
        var recordIDs: [String] = []
        defer {
            state.taskExecutionRecords.removeAll { recordIDs.contains($0.id) }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        let replyID = state.createTaskExecutionRecord(for: "解释 active turn")
        recordIDs.append(replyID)
        let replyRecord = state.taskExecutionRecords.first { $0.id == replyID }
        XCTAssertEqual(LingShuState.defaultSuccessStatus(for: replyRecord), .answered)

        let artifactID = state.createTaskExecutionRecord(for: "写入一个文件")
        recordIDs.append(artifactID)
        state.appendTaskRecordArtifact(artifactID, title: "结果文件", location: "/tmp/lingshu-status-evidence.txt", producer: "测试")
        let artifactRecord = state.taskExecutionRecords.first { $0.id == artifactID }
        XCTAssertEqual(LingShuState.defaultSuccessStatus(for: artifactRecord), .completed)

        let toolID = state.createTaskExecutionRecord(for: "运行验证命令")
        recordIDs.append(toolID)
        state.appendTaskRecordMessage(
            toolID,
            actor: "工具",
            role: "run_command 完成",
            kind: .agent,
            text: "exit 0",
            detail: .toolResult(tool: "run_command", success: true, output: "ok")
        )
        let toolRecord = state.taskExecutionRecords.first { $0.id == toolID }
        XCTAssertEqual(LingShuState.defaultSuccessStatus(for: toolRecord), .completed)

        let taskID = state.createTaskExecutionRecord(for: "做一个任务")
        recordIDs.append(taskID)
        state.bindGoalSpec(.init(objective: "做一个任务", kind: .task), to: taskID)
        let taskRecord = state.taskExecutionRecords.first { $0.id == taskID }
        XCTAssertEqual(LingShuState.defaultSuccessStatus(for: taskRecord), .completed)
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
        ], note: "", OAuth: .init(
            required: true,
            target: "当前网络里的 AirPlay/Chromecast 设备",
            action: "扫描本地网络设备发现信息",
            reason: "需要本地网络/设备发现授权后才能继续探测。",
            question: "这一步需要你授权本地网络/设备发现权限后才能继续扫描 AirPlay/Chromecast 设备。"
        )), to: rid)

        let block = state.userAuthorizationBlockIfNeeded(
            decision: .init(status: .blocked, reason: "结构化字段声明需要用户授权"),
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
        ], note: "", OAuth: .init(
            required: true,
            target: "外部知识库",
            action: "写入同步内容",
            reason: "需要用户完成账号授权或提供凭据。",
            question: "这一步需要你对外部知识库完成授权后才能继续。"
        )), to: rid)
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
        ], note: "", OAuth: .init(
            required: true,
            target: "外部知识库",
            action: "写入同步内容",
            reason: "需要用户完成账号授权或提供凭据。",
            question: "需要你对外部知识库授权或提供凭据后,我才能继续同步。"
        )), to: rid)
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
        ], note: "", OAuth: .init(
            required: true,
            target: "外部知识库",
            action: "写入同步内容",
            reason: "需要用户完成账号授权或提供凭据。",
            question: "需要你对外部知识库授权或提供凭据后,我才能继续同步。"
        )), to: rid)
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
        ], note: "", OAuth: .init(
            required: true,
            target: "外部系统",
            action: "写入同步内容",
            reason: "需要用户授权或提供凭据。",
            question: "这一步需要你授权外部系统后才能继续。"
        )), to: rid)
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

    // MARK: 只读观察/发现任务证据收口

    @MainActor
    func testReadOnlyObservationWithEvidenceCanFinishWithoutReview() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "看看当前环境有哪些可发现对象,只做发现和分类")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(
            objective: "扫描当前环境可发现对象并分类说明",
            kind: .task,
            successCriteria: ["列出发现对象并按类型分类"]
        ), to: rid)
        state.appendTaskRecordMessage(
            rid,
            actor: "工具",
            role: "跑命令",
            kind: .agent,
            text: "system_profiler SPUSBDataType",
            detail: .toolCall(tool: "run_command", summary: "system_profiler SPUSBDataType", arguments: "system_profiler SPUSBDataType")
        )
        state.appendTaskRecordMessage(
            rid,
            actor: "工具",
            role: "跑命令完成",
            kind: .result,
            text: "USB: Keyboard",
            detail: .toolResult(tool: "run_command", success: true, output: "USB:\n  Keyboard\n  Trackpad")
        )

        let reply = "已扫描当前环境:USB 输入设备 2 个,网络发现设备 0 个。我按输入设备和网络设备两类列出,未发现投屏设备。"
        XCTAssertTrue(state.readOnlyObservationDeliveryCanFinish(recordID: rid, userRequest: "看看当前环境有哪些可发现对象,只做发现和分类", reply: reply))
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .ok, "只读观察任务已有证据和结论时,不应被成功标准/缺口拖进返工循环")
    }

    @MainActor
    func testObservationWithoutEvidenceCannotFastFinish() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "看看当前环境有哪些可发现对象")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "扫描当前环境可发现对象", kind: .task, successCriteria: ["列出发现对象"]), to: rid)

        XCTAssertFalse(state.readOnlyObservationDeliveryCanFinish(
            recordID: rid,
            userRequest: "看看当前环境有哪些可发现对象",
            reply: "当前环境里有一些设备,我已经整理好了。"
        ), "没有工具/事实证据时不能靠嘴收口")
    }

    @MainActor
    func testMutatingTaskCannotUseObservationFastFinish() {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "生成一个报告文件保存到 /tmp/out.md")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(
            objective: "生成并保存报告文件",
            kind: .task,
            successCriteria: ["文件 /tmp/out.md 存在"]
        ), to: rid)
        state.appendTaskRecordMessage(
            rid,
            actor: "工具",
            role: "跑命令",
            kind: .agent,
            text: "ls /tmp",
            detail: .toolCall(tool: "run_command", summary: "ls /tmp", arguments: "ls /tmp")
        )
        state.appendTaskRecordMessage(
            rid,
            actor: "工具",
            role: "跑命令完成",
            kind: .result,
            text: "ok",
            detail: .toolResult(tool: "run_command", success: true, output: "foo")
        )

        XCTAssertFalse(state.readOnlyObservationDeliveryCanFinish(
            recordID: rid,
            userRequest: "生成一个报告文件保存到 /tmp/out.md",
            reply: "我看到了 /tmp 目录,准备生成文件。"
        ), "写文件/生成交付物任务必须走真实产出与验收,不能走观察收口")
    }

    @MainActor
    func testObservationStructuredOAuthCannotFastFinish() async {
        let state = LingShuState()
        let rid = state.createTaskExecutionRecord(for: "看看现在网络里有没有可投屏设备")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == rid }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }
        state.bindGoalSpec(.init(objective: "扫描当前网络里的可投屏设备", kind: .task, successCriteria: ["列出可投屏设备"]), to: rid)
        state.appendTaskRecordMessage(
            rid,
            actor: "工具",
            role: "跑命令",
            kind: .agent,
            text: "dns-sd -B _airplay._tcp",
            detail: .toolCall(tool: "run_command", summary: "dns-sd -B _airplay._tcp", arguments: "dns-sd -B _airplay._tcp")
        )
        state.appendTaskRecordMessage(
            rid,
            actor: "工具",
            role: "跑命令完成",
            kind: .result,
            text: "ok",
            detail: .toolResult(tool: "run_command", success: true, output: "Browsing for _airplay._tcp")
        )

        let reply = #"{"reply":"这一步需要你授权本地网络/设备发现权限后才能继续扫描 AirPlay 设备。","completion":{"status":"waiting_for_user","reason":"缺少本地网络/设备发现授权","needs_user":true},"OAuth":{"required":true,"target":"本地网络设备发现","action":"扫描 AirPlay 设备","reason":"需要系统授权本地网络/设备发现权限","question":"是否授权我扫描当前网络里的 AirPlay 设备?","options":[{"label":"确认授权","detail":"允许本次扫描"},{"label":"暂不授权","detail":"停止扫描"}]}}"#
        XCTAssertFalse(state.readOnlyObservationDeliveryCanFinish(recordID: rid, userRequest: "看看现在网络里有没有可投屏设备", reply: reply))
        let decision = await state.computeCompletionDecision(taskRecordID: rid, reply: reply)

        XCTAssertEqual(decision.status, .waitingForUser, "OAuth 结构字段声明真需要用户授权时仍应进入人机确认,不能被观察收口吞掉")
    }
}
