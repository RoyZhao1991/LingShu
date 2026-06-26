import Foundation

/// 编排器事件桥接子域:把 `LingShuAgentOrchestrator` 的子任务事件接到 UI(独立任务记录 + 对话回灌),
/// 并在子任务收尾时把**简报**回灌主线程(信息同步,非完整上下文)。从 AgentBackbone 拆出,各管一段。
@MainActor
extension LingShuState {

    /// 把编排器事件桥接到 UI:子任务建成独立任务记录(任务号 + 列表),结果/卡住/失败回灌对话 + 简报主线程。
    func installAgentEventSinkIfNeeded() {
        guard !agentEventSinkInstalled else { return }
        agentEventSinkInstalled = true
        startConnectivityMonitorIfNeeded()
        loadDeliverablesIfNeeded()   // 从增量存储恢复最近产出物(跨重启续上"运行起来/继续")+ 启定时压缩
        let orchestrator = agentOrchestrator
        Task { await orchestrator.setEventSink { @MainActor [weak self] event in
            self?.handleOrchestratorEvent(event)
        } }
        // 子任务也接**验收 + 恢复**:委托主线程统一的 verifyAndContinue(撞顶恢复 + 多轮验收 + 测试/运行门 + 停滞交还),
        // 子任务与主线程同一套执行恢复力——复杂工程撞顶/崩溃会自己续跑修到跑通,而非直接判异常。
        Task { await orchestrator.setAcceptanceHook { @MainActor [weak self] subID, objective, session, initial in
            guard let self else { return initial }
            let rid = self.agentSubTaskRecords[subID]
            // **maker session ≠ checker session(用户硬性要求:LOOP 必须两个独立角色 session,哪怕都是 GLM)**:
            // - 默认(本地脑 maker)→ checker 用**独立 agent 会话** `runCheckerSession`(useCheckerSession),它自己读代码/跑测试独立验收;
            // - maker 是外部 agent(@Codex)→ checker 走 `runIndependentAgentCheckerIfNeeded`(另一个 agent 进程 / 异源审查员)。
            let binding = rid.flatMap { self.taskReviewBindings[$0] }
            let hasExternalRole = binding?.maker.kind == .externalCLI || binding?.checker.kind == .externalCLI
            // **唯一 checker(消除双重验收)**:任一方是外部 agent → 由 runIndependentAgentCheckerIfNeeded 跑(agent checker),
            // verifyAndContinue 跳过内部审查员;都本地(灵枢自建双角色)→ verifyAndContinue 用**独立 GLM checker 会话**。
            let verified = await self.verifyAndContinue(session: session, result: initial, userRequest: objective,
                                                        taskRecordID: rid, useCheckerSession: !hasExternalRole, skipReview: hasExternalRole)
            return await self.runIndependentAgentCheckerIfNeeded(recordID: rid, makerResult: verified, objective: objective)
        } }
    }

    func handleOrchestratorEvent(_ event: LingShuOrchestratorEvent) {
        // 派发任务进入终态(完成/失败/卡住/中断)→ 收掉 LOOP 相位,别让本体停在"执行中"不灭。
        switch event {
        case .completed, .failed, .blocked, .interrupted: setLoopPhase(.idle)
        default: break
        }
        switch event {
        case .spawned(let id, let objective):
            // spawn_team 的命名角色共享父任务记录,由 runRoleAgent 自己把开始/产出写回父时间线;
            // 角色不是新的顶层离散目标,不能在这里污染独立任务列表或单独收尾父任务。
            guard !isRoleAgentEventID(id) else { return }
            // 主线程分诊派发的任务 / 模型 spawn_task 已**预映射**到自己的记录,复用之;否则给未知外部派生兜底建一条。
            let preMapped = agentSubTaskRecords[id]
            let recordID = preMapped ?? createTaskExecutionRecord(for: objective)
            agentSubTaskRecords[id] = recordID
            appendTaskRecordMessage(recordID, actor: "灵枢", role: "派生子任务", kind: .router, text: "派生并行子任务:\(objective)")
            // 兜底入口:正常 spawn_task 已在派生前预建记录并绑定 GoalSpec;这里仅防未来外部直接走 orchestrator。
            if preMapped == nil, goalSpecEnabled, goalSpec(for: recordID) == nil {
                bindGoalSpec(
                    LingShuGoalSpec(objective: objective, kind: .task, successCriteria: ["完成并可验证子目标:\(objective)"]),
                    to: recordID
                )
            }
        case .completed(let id, let objective, let summary):
            guard !isRoleAgentEventID(id) else { return }
            let recordID = agentSubTaskRecords[id]
            if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }   // 收尾即解除"等回答"
            // P2 真闭环:终态由完成闸定(防伪完成)——派发任务即便 orchestrator 报 completed,
            // 若完成闸判 partial/waitingForUser/blocked,则按真实状态收尾、且**不报「做好了」**。
            let outcome = recordID.flatMap { rid in taskExecutionRecords.first { $0.id == rid }?.taskOutcome }
            let status = Self.finishStatus(for: outcome, fallback: .completed)
            let trulyDone = status == .completed || status == .verified
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: trulyDone ? "结果" : "未竟", kind: trulyDone ? .result : .warning, text: summary)
                finishTaskRecord(recordID, status: status, summary: summary)
                if trulyDone {
                    recordDeliverable(recordID: recordID, title: objective, summary: summary)   // 登记产出物供"运行起来/继续"接上
                }
            }
            if trulyDone {
                briefMainThread("子任务「\(objective)」已完成:\(summary.prefix(200))")
                promoteSubtaskKnowledge(objective: objective, summary: summary)   // M3:子线程知识蒸馏进常驻主脑(v2),事后主线程可召回
                // **完成汇报时机(用户定调 2026-06-19,通用):一律入待汇报队列,由 drain 择机发——互动中捎带下次主线程汇报、待机则主动出声。**
                deliverOrQueueSubtaskReport(recordID: recordID, objective: objective, summary: summary)
            } else {
                // 未真完成:如实回灌(summary 已含完成闸的诚实补尾),不入"做好了"汇报队列。
                let label = status == .waitingForUser ? "⏸ 等待前提" : (status == .partial ? "⚠️ 部分完成" : "⚠️ 未能完成")
                postOrchestratorChat(recordID: recordID, dispatched: summary, spawned: "\(label):子任务「\(objective)」——\(summary.prefix(200))")
                briefMainThread("子任务「\(objective)」\(label):\(summary.prefix(180))")
                // 续接优先恢复:待用户/部分完成的派发任务 → 指向它,用户下条消息直接续这条隔离会话(spec 第14条)。
                if status == .waitingForUser || status == .partial, let recordID { blockedDispatchedRecordID = recordID }
            }
        case .blocked(let id, let objective, let question):
            guard !isRoleAgentEventID(id) else { return }
            let cleanQuestion = LingShuHumanInputEnvelope.userFacingText(from: question)
            let recordID = agentSubTaskRecords[id]
            if isBogusBuiltInCapabilityHandback(question) {
                let correction = builtInCapabilityCorrection(for: question)
                if let recordID {
                    appendTaskRecordMessage(recordID, actor: "能力图谱", role: "纠偏", kind: .router,
                                            text: "子任务误把已注册本地能力交还用户授权,已自动纠偏并继续执行。")
                }
                briefMainThread("子任务「\(objective)」误判本地能力授权,已纠偏继续执行。")
                let orchestrator = agentOrchestrator
                Task { await orchestrator.resumeWithInput(id: id, input: correction) }
                return
            }
            if let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "卡住", kind: .warning, text: cleanQuestion)
                blockedDispatchedRecordID = recordID   // 等用户回答→下条主输入直接续这条隔离会话(不重新分诊)
                // P2 真闭环:ask_user 阻塞=在等用户 → 状态显示「待用户」而非笼统「执行中」(修"状态很怪");不 finishTaskRecord(保留续接语义)。
                taskExecutionRecords[idx].status = .waitingForUser
                if taskExecutionRecords[idx].taskOutcome == nil { taskExecutionRecords[idx].taskOutcome = .waitingForUser }
                persistTaskExecutionRecords()
            }
            // **气泡内待输入(2026-06-23,监工"卡住的任务被聊天淹没、回复对不上"修)**:把这条任务的气泡标成「待你输入」,
            // 渲染气泡内回复控件(选项/追加信息),答复直达该隔离会话——不再靠分诊在历史里找回它。
            if let recordID {
                markDispatchedBubbleAwaitingInput(recordID: recordID, question: question)
            } else {
                chatMessages.append(.init(speaker: "灵枢", text: "⏸ 等待前提:子任务「\(objective)」——\(cleanQuestion)", isUser: false, choices: LingShuChoiceParsing.parse(question) ?? LingShuChoiceParsing.parse(cleanQuestion)))
            }
            briefMainThread("子任务「\(objective)」卡住,等待用户补充:\(cleanQuestion.prefix(160))")
        case .failed(let id, let objective, let summary):
            guard !isRoleAgentEventID(id) else { return }
            let recordID = agentSubTaskRecords[id]
            if recordID == blockedDispatchedRecordID { blockedDispatchedRecordID = nil }
            // P2 真闭环:即便模型撞顶/停滞被判 failed,若完成闸早已判 waitingForUser/partial(如缺凭据需用户),
            // 以完成闸为准——给出「需要你…」的诚实收尾,而不是笼统「异常」,并指向它便于续接。
            let outcome = recordID.flatMap { rid in taskExecutionRecords.first { $0.id == rid }?.taskOutcome }
            let status = Self.finishStatus(for: outcome, fallback: .blocked)
            let honest = recordID.flatMap { outcomeAwareSummary(recordID: $0, base: summary) } ?? summary
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: status == .waitingForUser ? "待用户" : "失败", kind: .warning, text: honest)
                finishTaskRecord(recordID, status: status, summary: honest)
                if status == .waitingForUser || status == .partial { blockedDispatchedRecordID = recordID }
            }
            let head = status == .waitingForUser ? "⏸ 等待前提" : (status == .partial ? "⚠️ 部分完成" : "⚠️ 未能自行收尾")
            postOrchestratorChat(recordID: recordID, dispatched: honest, spawned: "\(head):子任务「\(objective)」——\(honest.prefix(220))")
            briefMainThread("子任务「\(objective)」\(head):\(honest.prefix(160))")
        case .interrupted(let id, let objective, let reason):
            guard !isRoleAgentEventID(id) else { return }
            if LingShuModelServiceFailure.isNonRecoverableReason(reason) {
                let message = LingShuModelServiceFailure.userFacingReason(reason)
                let status = LingShuModelServiceFailure.decodeReason(reason)?.taskStatus ?? .failed
                let recordID = agentSubTaskRecords[id]
                if let recordID {
                    appendTaskRecordMessage(recordID, actor: "模型通道", role: "不可自动恢复", kind: .warning, text: message)
                    finishTaskRecord(recordID, status: status, summary: message)
                    if status == .waitingForUser { blockedDispatchedRecordID = recordID }
                }
                let head = status == .waitingForUser ? "⏸ 需要处理模型配置" : "⚠️ 模型服务异常"
                postOrchestratorChat(recordID: recordID, dispatched: message, spawned: "\(head):子任务「\(objective)」——\(message.prefix(220))")
                briefMainThread("子任务「\(objective)」\(head):\(message.prefix(160))")
                return
            }
            // 网络/网关中断:**非失败**,标"已暂停",启动主动重试循环(它在主对话框统一展示重试进度,故这里不另发对话气泡)。
            _ = objective
            let recordID = agentSubTaskRecords[id]
            if let recordID {
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "暂停", kind: .warning, text: "网络中断,已暂停:\(reason)")
                finishTaskRecord(recordID, status: .suspended, summary: "网络中断已暂停,联网后自动续跑。")
            }
            startNetworkRetryLoopIfNeeded()
        case .resumed(let id, let objective):
            guard !isRoleAgentEventID(id) else { return }
            // 重连/手动续接:从"已暂停"翻回"执行中",执行流继续追加进该记录窗口。
            let recordID = agentSubTaskRecords[id]
            if let recordID, let idx = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) {
                taskExecutionRecords[idx].status = .running
                appendTaskRecordMessage(recordID, actor: "灵枢", role: "续跑", kind: .router, text: "网络恢复,自动接着跑。")
                persistTaskExecutionRecords()
            }
            _ = objective
        }
        // 任务收尾/卡住/中断都可能释放并发槽 → 看队列区有没有该晋级派发的(idempotent:满则 no-op)。
        promoteQueuedDispatchIfPossible()
    }

    private func isRoleAgentEventID(_ id: String) -> Bool {
        id.hasPrefix("role-")
    }

    /// 编排器结果回灌对话:**主线程分诊派发**的任务回填它自己的加载气泡(不另起一条);
    /// **模型 spawn_task** 的子任务则追加一条新气泡(它本就没有预建气泡)。
    private func postOrchestratorChat(recordID: String?, dispatched: String, spawned: String) {
        if let recordID, dispatchedTaskBubbles[recordID] != nil {
            fillDispatchedBubble(recordID, text: dispatched)
        } else {
            chatMessages.append(.init(speaker: "灵枢", text: spawned, isUser: false, taskRecordID: recordID, choices: LingShuChoiceParsing.parse(spawned)))
        }
    }

    /// 此刻是否"在和主人互动/占屏中"(演示开着 / 在飞回合 / 正在朗读)——用于决定子任务完成汇报是**捎带**(别打断)还是**主动出声**。
    var isEngagedInInteraction: Bool {
        previewController.isPresented || hasActiveModelCall || autonomousRunTask != nil || (voiceManager?.isSpeakingOrQueued == true)
    }

    /// 子任务完成 → **一律入待汇报队列**(回填它的派发气泡作记录、并标记已念以抑制自动朗读=不在此刻打断互动)。
    /// 真正的汇报由 drain 择机发:互动中捎带下次主线程回复(finishAutonomousRun)、待机时主动出声(deliverPendingReportsIfIdle)。
    func deliverOrQueueSubtaskReport(recordID: String?, objective: String, summary: String) {
        let report = "你交代的「\(objective)」我做好了:\(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))"
        if pendingSubtaskReports.isEmpty { firstPendingReportAt = Date() }   // 本批第一个完成,记起点(防抖上限用)
        lastSubtaskReportEnqueuedAt = Date()                                 // 刷新"最近完成"时刻(防抖:接连完成的合并)
        pendingSubtaskReports.append(String(report))
        if let recordID, let bid = dispatchedTaskBubbles[recordID] {
            fillDispatchedBubble(recordID, text: "✅ \(summary)")   // 回填,别让派发气泡空转
            lastSpokenMessageID = bid                                // 标记已念→抑制自动朗读,汇报择机由 drain 统一发
        }
        appendTrace(kind: .system, actor: "灵枢", title: "子任务完成·入待汇报队列", detail: String(report.prefix(36)))
    }

    /// 取出并清空待汇报队列(供"捎带"拼进主线程回复)。多条**合并**成一条:单条直接;多条加序号,免零散乱。
    func drainPendingSubtaskReports() -> String {
        guard !pendingSubtaskReports.isEmpty else { return "" }
        let items = pendingSubtaskReports
        pendingSubtaskReports.removeAll()
        firstPendingReportAt = nil
        if items.count == 1 { return items[0] }
        let numbered = items.enumerated().map { "\($0.offset + 1)、\($0.element)" }.joined(separator: " ")
        return "刚才你交代的几件都办好了:\(numbered)"
    }

    /// 待机时主动汇报待汇报队列(贴气泡→自动朗读=主动出声)。在自主 1s 自驱循环里每拍调。
    /// **单线程顺序 + 合并接连完成**:① 正在念报告/互动中(`isEngagedInInteraction` 含 isSpeakingOrQueued)→ 不发,攒着(下一条等当前念完);
    /// ② **防抖合并**:最近一次完成后等 ~2.5s 稳定(其间又完成的一并并入)再一起报,免一个个零散刷;最长等 12s 兜底必发。
    func deliverPendingReportsIfIdle() {
        guard isStandingPersonOnDuty, !pendingSubtaskReports.isEmpty, !isEngagedInInteraction else { return }
        let now = Date()
        let stable = now.timeIntervalSince(lastSubtaskReportEnqueuedAt) >= 2.5    // 队列稳定(无新完成)= 这批接连完成的已到齐
        let maxWaited = firstPendingReportAt.map { now.timeIntervalSince($0) >= 12 } ?? false   // 兜底:别因持续 trickle 永远不报
        guard stable || maxWaited else { return }
        let text = drainPendingSubtaskReports()
        chatMessages.append(.init(speaker: "灵枢", text: "✅ \(text)", isUser: false))   // 末条灵枢气泡→ speakLatestReplyIfNeeded 自动朗读=主动汇报
        appendTrace(kind: .result, actor: "灵枢", title: "主动汇报(待机)", detail: String(text.prefix(40)))
    }

    /// 子任务进展回灌主线程(信息同步,非完整上下文):只把**简报摘要**注入常驻主会话,
    /// 主线程下次作答即知悉,不搬子任务的完整 transcript(对齐 codex 的 subagent 汇报)。
    func briefMainThread(_ brief: String) {
        let session = mainAgentSessionHolder
        Task { await session?.injectBriefing(brief) }
    }

    // MARK: - 断网重连自动续跑

    /// 懒启动网络可达性监控(首次有 agent 活动时):不可达→可达(去抖后)→ 回 MainActor 续跑所有暂停的任务。
    func startConnectivityMonitorIfNeeded() {
        guard connectivityMonitor == nil else { return }
        let monitor = LingShuConnectivityMonitor(onReconnect: { [weak self] in
            // 链路恢复:唤醒主动重试循环立即再试(重置退避),而不是直接续跑——让重试进度在对话框可见。
            Task { @MainActor in self?.triggerImmediateNetworkRetry() }
        })
        connectivityMonitor = monitor
        monitor.start()
    }

    /// 网络恢复:让编排器逐条从中断处续跑暂停的子任务,并续跑可能挂起的主会话回合。
    func resumeSuspendedWork() async {
        let ids = await agentOrchestrator.suspendedIDs()
        if !ids.isEmpty {
            appendTrace(kind: .route, actor: "网络", title: "重连", detail: "网络恢复,自动续跑 \(ids.count) 条暂停任务。")
        }
        for id in ids { await agentOrchestrator.resumeInterrupted(id: id) }
        await resumeSuspendedMainTurnIfNeeded()
        await resumeSuspendedAutonomousIfNeeded()
    }

    /// 续跑因断网挂起的**主会话**回合:按记录边界重放当前 prompt + 再过验收,把结果填回原气泡;
    /// 若续跑又因网络 .interrupted,则保留挂起态等下次重连。
    func resumeSuspendedMainTurnIfNeeded() async {
        guard let pending = suspendedMainTurn else { return }
        suspendedMainTurn = nil
        appendTrace(kind: .route, actor: "网络", title: "续跑主回合", detail: "网络恢复,接着把上一条跑完。")
        // 共享主会话在网络中断时可能已经累积多条未收口输入。恢复时如果直接 continueLoop(),
        // 模型会把多个暂停问答揉到同一个气泡里补答。这里重建主会话,按本记录边界重放当前 prompt:
        // 保留长期记忆 seed,但丢弃断流期间的悬空轮次,确保一问一答不串台。
        mainAgentSessionHolder = nil
        let session = await mainAgentSession()
        await session.setTextDeltaSink { [weak self] delta in
            await MainActor.run { self?.appendStreamingBubbleText(delta, to: pending.bubbleID) }
        }
        let recoveryGuidance = """
        【网络恢复续跑边界】
        这次只恢复当前这一条被暂停的请求,不要回答其它历史问题、排队问题或其它暂停记录。
        当前请求如下:
        \(pending.prompt)
        """
        let result = await driveAgentDelivery(
            session: session,
            prompt: pending.prompt,
            guidance: recoveryGuidance,
            taskRecordID: pending.recordID,
            trustReplyClaim: false
        )
        if case .interrupted = result {
            suspendedMainTurn = pending   // 还是连不上,继续挂起等下次重连
            return
        }
        finalizeMainTurn(result: result, bubbleID: pending.bubbleID, recordID: pending.recordID, prompt: pending.prompt, startedAt: pending.startedAt)
    }
}
