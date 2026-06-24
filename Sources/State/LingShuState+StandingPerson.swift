import Foundation

/// 常驻灵枢（独立运行的新形态，用户定调 2026-06-16）。
/// 取向：独立运行模式启动后，灵枢就是一个**能听、能说、能思考、能动手的"人"**——
/// 不再要求预先写一个一次性「目标」。上岗后由对话/语音自然驱动它行动；执行带其权限级与全套四肢。
/// 与目标驱动的独立运行（prepareAutonomousRun，仍保留给"进入独立运行模式 + 一句话目标"的命令路径）解耦。
@MainActor
extension LingShuState {

    /// 常驻灵枢在岗中：无单一目标（空 objective）且状态机已经进入运行/暂停等非 idle 态。
    ///
    /// 注意:会话对象(`autonomousSessionHolder`)是在上岗后异步构造的,不能把它作为"是否上岗"的判据。
    /// 否则控制端/状态栏会在启动窗口期误报未上岗,长跑和用户都会看到 on/off 抖动。
    /// 真要接管输入时仍在 `handleStandingPersonInputIfNeeded` 里要求 session 存在。
    var isStandingPersonOnDuty: Bool {
        autonomousRun.phase != .idle
            && autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 让灵枢「上岗」成为常驻灵枢：不需要预设目标——环境自检通过即直接上岗（能听/能说/能思考/能动手），
    /// 之后由对话/语音自然驱动。环境有阻断项则不上岗，提示先处理。
    func goLiveAsStandingPerson() {
        // 已在岗就不再重新上岗 + 重打招呼(否则每点一次「上岗」都堆一句欢迎语)。
        guard !isStandingPersonOnDuty else {
            appendTrace(kind: .system, actor: "灵枢", title: "已在岗", detail: "无需重复上岗,直接说话即可。")
            return
        }
        let now = Date()
        autonomousAttachmentContext = attachmentContextBlock()   // 可选：上岗时带的素材
        clearAttachments()
        autonomousObjectiveDraft = ""
        let environment = autonomousEnvironmentProbe.run(input: autonomousEnvironmentInput(), now: now)
        let canRun = environment.canRun
        autonomousRun = .init(
            id: "auto-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(6))",
            objective: "",                       // 空目标 = 常驻灵枢（不是某个一次性任务）
            phase: canRun ? .ready : .blocked,
            permissionLevel: autonomousPermissionLevel,
            environment: environment,
            selfCheck: nil,
            runbook: nil,
            statusLine: canRun ? "灵枢准备上岗。" : "环境存在阻断项，请先处理后再上岗。",
            startedAt: nil,
            updatedAt: now
        )
        guard canRun else {
            missionTitle = "灵枢上岗受阻"
            missionStatus = environment.summaryLine
            appendTrace(kind: .warning, actor: "灵枢", title: "上岗受阻", detail: environment.summaryLine)
            return
        }
        appendTrace(kind: .system, actor: "灵枢", title: "环境自检", detail: environment.summaryLine)
        authorizeAutonomousRun()
    }

    /// 复杂多交互任务(演示 PPT / 讲解 / 开会 / 答疑……)**默认进自主运行模式**(用户定调 2026-06-17):
    /// 这类任务要灵枢占屏 + 出声 + 全程跟人互动,正是自主模式为之设计的——本体浮窗全程在位、手动接管安全闸生效。
    /// 做法:把这件事暂存为「上岗后第一件事」,然后上岗;上岗的开场白即直接做它(见 launchAutonomousExecution + standingTaskKickoffPrompt)。
    /// 若已在岗,则不重复上岗,直接当在岗输入喂进去。
    func goLiveForInteractiveTask(prompt: String) {
        if isStandingPersonOnDuty {
            _ = handleStandingPersonInputIfNeeded(prompt: prompt, taskRecordID: nil)
            return
        }
        pendingStandingKickoff = prompt
        enteringViaManagedHandoff = true   // 托管转入:本体立即出现,不放 2.5s 入场仪式(免演示开场那段没本体/被仪式盖住)
        appendTrace(kind: .route, actor: "灵枢", title: "交互任务→自主模式", detail: String(prompt.prefix(40)))
        goLiveAsStandingPerson()
        // 只在上岗**受阻**(环境阻断,phase 同步即为 .blocked)时清待办。不能用 isStandingPersonOnDuty 判断——
        // 它要求 autonomousSessionHolder!=nil,而会话是在 launchAutonomousExecution 里**异步**建的,此刻还没建好,
        // 误判会把刚存的待办清掉,导致开场退回寒暄而非干活(实测 bug)。
        if autonomousRun.phase != .running { pendingStandingKickoff = nil }
    }

    /// 启动语选择:在岗且有暂存的交互任务 → 开场即做它(取代寒暄);否则走常规启动语(寒暄/目标驱动)。用完即清待办。
    func resolveKickoffPrompt(objective: String, runbook: LingShuAutonomousRunbook?) -> String {
        if objective.isEmpty, let task = pendingStandingKickoff {
            pendingStandingKickoff = nil
            return standingTaskKickoffPrompt(task)
        }
        return autonomousKickoffPrompt(objective: objective, runbook: runbook)
    }

    /// 首轮启动语：把目标 + runbook 降为「建议性上下文」喂给模型（不再当硬流程）。
    /// (从 LingShuState+AutonomousRun 移来,守住单文件 ≤500 行;kickoff 与 resolveKickoffPrompt 同域。)
    func autonomousKickoffPrompt(objective: String, runbook: LingShuAutonomousRunbook?) -> String {
        // 常驻灵枢:不下达目标,只让它示意已进入自主运行状态、在听,然后待命。
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var lines = ["**现在进入「自主运行状态」**:你已上岗,能听、能说、能看屏幕、能动手。用一句简短自然的话(用 `speak` 出声)向主人打个招呼、示意你已进入自主运行状态并就位待命,就一句即可。**打招呼时别用具体名字称呼**(历史里若出现过某个名字,可能是语音误识别,不可靠)——用「主人」或干脆不带称呼。之后主人一开口提问或下指令,你就**全力正面回应**(该答就答全、该做就做完),绝不用'在岗待命/随时吩咐'这类空话敷衍。现在只打这一句招呼。"]
            if !autonomousAttachmentContext.isEmpty { lines.append(autonomousAttachmentContext) }
            return lines.joined(separator: "\n")
        }
        var lines = ["独立运行目标：\(objective)"]
        if !autonomousAttachmentContext.isEmpty { lines.append(autonomousAttachmentContext) }   // 上传的文件素材
        if let runbook {
            if !runbook.assumptions.isEmpty { lines.append("已知假设：" + runbook.assumptions.joined(separator: "；")) }
            if !runbook.expectedArtifacts.isEmpty { lines.append("期望产出物：" + runbook.expectedArtifacts.joined(separator: "、")) }
            if !runbook.reviewGates.isEmpty { lines.append("验收要点：" + runbook.reviewGates.joined(separator: "、")) }
            let stepTitles = runbook.steps.map(\.title)
            if !stepTitles.isEmpty { lines.append("建议步骤（仅供参考，可自行规划）：" + stepTitles.joined(separator: " → ")) }
        }
        if let skillHint = matchedSkillHint(for: objective) { lines.append(skillHint) }
        lines.append("现在开始自主推进，直到目标达成；完成后用一句话总结产出物与结论。")
        return lines.joined(separator: "\n")
    }

    /// 上岗即开干这件交互任务的开场指令(取代寒暄开场白):告诉灵枢现在要当面演示/讲解/主持,
    /// 用 speak 一句句讲、讲 PPT 用 open_preview/present_fullscreen,逐页讲完再翻页,全程留在岗等人插话/提问。
    func standingTaskKickoffPrompt(_ task: String) -> String {
        var lines = [
            "**你已上岗进入「自主运行状态」,当面给主人完成这件事**:\(task)",
            "这是一次需要你**占屏 + 出声 + 全程在场互动**的任务。请直接开始做,不要先寒暄。",
            "若是演示/讲 PPT:`open_preview` 打开 → `preview_document_text` **一次性读完整篇、想好每页讲稿** → `present_fullscreen(true)` 进全屏 → **`run_steps` 一次性排上 [speak 第1页讲稿 → preview_next → speak 第2页 → preview_next → …] 批量顺滑播完**(别逐页一步步往返,会卡)→ `present_fullscreen(false)` 退。主人中途插话会自动打断批量,你答完问一句「要继续吗」,他说继续就从断点页 run_steps 续上。",
            "若是开会/答疑:用 `speak` 主持与应答。全程**留在岗**,主人随时可能插话或提问,你正面接住、答完接着推进。"
        ]
        if !autonomousAttachmentContext.isEmpty { lines.append(autonomousAttachmentContext) }
        return lines.joined(separator: "\n")
    }

    /// 灵枢在岗时，用户对话/语音 → 直接喂给在岗的执行会话（带其权限级与四肢），让它真去做，
    /// 而不是另起一个无权限的主回合。返回非 nil 表示已接管本轮输入；真实回复由 finishAutonomousRun 的在岗分支回灌。
    ///
    /// **通用 LOOP 人机讨论（不是 PPT 定制）**：
    /// - 在岗会话**此刻正在跑一条回合**（演示/连续任务进行中）→ 把这句当作「中途插话」**注入正在跑的那条脑回路**
    ///   （`injectCorrection`，回合边界安全采纳）——不打断、不重启:大脑先口头回应,再按需接着从当前进度推进。
    ///   这套机制对任何长回合通用（演示 PPT、开会、跑长任务……),配合麦克风打断 TTS = 随时插入讨论再续。
    /// - 在岗会话**空闲**（上一段已收尾）→ 起一条新回合续跑（resume）。
    func handleStandingPersonInputIfNeeded(prompt: String, taskRecordID: String?) -> String? {
        guard isStandingPersonOnDuty else { return nil }
        guard let session = autonomousSessionHolder else {
            let addition = "主人补充/追问:\(prompt)"
            if let pending = pendingStandingKickoff, !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingStandingKickoff = pending + "\n\n" + addition
            } else {
                pendingStandingKickoff = addition
            }
            missionStatus = "正在进入自主模式,这句已并入待处理上下文。"
            appendTrace(kind: .route, actor: "灵枢", title: "在岗启动中接令", detail: String(prompt.prefix(40)))
            return ""
        }
        // **暂停态:任何输入都不起回合(2026-06-20)**:暂停 = 全停下等手动「继续」(`resumeAutonomousRun` 按钮),
        // 语音/唤醒词/文字都不该绕过暂停拉起新处理。给一句提示、消费掉这条输入(返回 "" = 已接管不再下发)。
        if autonomousRun.phase == .paused {
            missionStatus = "已暂停,点「继续」我才接着听你说。"
            appendTrace(kind: .system, actor: "灵枢", title: "暂停中·忽略输入", detail: String(prompt.prefix(24)))
            return ""
        }
        // **"退出演示/关闭演示"= 确定性关掉演示窗(2026-06-19 修"说退出演示却没退")**:实测 DeepSeek 口头答应却不调
        // present_fullscreen(false),故命中显式退出命令 + 预览正开着 → 不走大脑,直接停批量/掐TTS/关预览/抑制重弹 + 出声确认。
        if previewController.isPresented, LingShuNestedStagePlanner.isExitPresentationCommand(prompt) {
            return exitPresentationDeterministically(prompt: prompt)
        }
        let recordID = autonomousRunRecordID ?? createTaskExecutionRecord(for: "灵枢在岗")
        autonomousRunRecordID = recordID
        appendTaskRecordMessage(recordID, actor: "主人", role: "指令", kind: .core, text: prompt)

        if previewController.isPresented, LingShuInteractionFulfillment.isVisiblePresentationControl(prompt) {
            handleVisiblePresentationControl(prompt: prompt, recordID: recordID)
            return ""
        }

        // **互动 vs 执行,对新输入处理不同(用户定调 2026-06-19,通用"像一个人"逻辑)**:
        if autonomousRunTask != nil {
            // ── 互动中(演示/预览开着)= 接收任务的场合 ──:不放弃当前互动,**注入让大脑判断**:
            //   控制(继续/翻页)当场做;"放下一切马上做"的紧急任务→当场做;其余新任务→ spawn_task 派后台、接着演示。
            //   先停批量+掐 TTS 让大脑有机会在回合边界采纳这次注入。
            if previewController.isPresented {
                batchInterruptRequested = true
                interruptSpeechOutput?()
                appendTrace(kind: .system, actor: "灵枢", title: "互动中收到输入", detail: String(prompt.prefix(40)))
                missionStatus = "收到,正在判断…"
                let framed = interactionInputFraming(prompt)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let caught = await session.injectCorrection(framed)
                    if !caught { self.resumeStandingSession(session: session, prompt: prompt, recordID: recordID, sentText: framed) }
                }
                return ""
            }
            // ── 执行任务中(非互动)= 单线程·打断即放弃 ──:直接放弃执行中的工作,起全新回合处理新指示("继续"交大脑据上下文判)。
            batchInterruptRequested = true
            interruptSpeechOutput?()
            appendTrace(kind: .system, actor: "灵枢", title: "打断·放弃执行中", detail: String(prompt.prefix(40)))
            missionStatus = "收到,放下手头的事,正在回应…"
            resumeStandingSession(session: session, prompt: prompt, recordID: recordID, sentText: interruptedResumeFraming(prompt))
            return ""
        }

        resumeStandingSession(session: session, prompt: prompt, recordID: recordID)
        return ""   // 已接管：真实回复由 finishAutonomousRun 的在岗分支回灌
    }

    /// 「互动中收到新输入」给大脑的判断措辞(通用"像一个人":互动=接收任务的场合)。
    func interactionInputFraming(_ prompt: String) -> String {
        """
        [主人在互动(演示/答疑)中对你说话 · 最高优先级] \(prompt)
        像一个正在做演示的人那样判断这句是什么、并据此处理:
        · **控制当前互动**(继续/下一页/上一页/跳到第X页/这页讲细点/停下)→ 当场照做,处理完**从当前进度接着演示**,不重头。
        · **要你"放下手里一切、马上去做"的紧急任务**→ 停下当前互动,马上做。
        · **其余只是顺手安排的新任务**(非紧急,如"顺便帮我做个X")→ **别打断演示**:用 `spawn_task` 把它派到后台并行做,口头一句"好,记下了,我后台做完汇报你",然后**从当前进度接着演示**。后台任务完成后系统会择机汇报,你不用守着它。
        不要把这次说话当成把整件事从头重来。
        """
    }

    /// 在岗空闲时起一条新回合续跑（与插话注入区分）。**不再前置感知态势**——
    /// 直接问的问题就干净地答(屏幕变化只静默监测,要看屏自己 screen_capture),避免"介绍一下你自己"被态势前缀污染成"在岗待命"。
    /// `sentText`:真正发给模型的文本(默认=prompt);打断续接时传"打断措辞"包装版,而 trace/状态仍用 prompt 原文,不污染界面。
    /// 在岗答复**流式气泡收尾**:有流式气泡 → `finalizeStreamingBubble` 定稿(逐字临时文本换成验收后最终回复;text 空→移除 partial),
    /// 返回 true(调用方不必再 append);**无流式气泡**(开场招呼/目标驱动独立运行)→ 返回 false,调用方走原 append。供 finishAutonomousRun 收尾用。
    @discardableResult
    func settleStandingStreamBubble(text: String, recordID: String?) -> Bool {
        guard let id = standingStreamingBubbleID else { return false }
        standingStreamingBubbleID = nil
        finalizeStreamingBubble(id, text: text, taskRecordID: recordID)
        return true
    }

    func resumeStandingSession(session: any LingShuAgentSessioning, prompt: String, recordID: String, sentText: String? = nil) {
        enterAutonomousRunningState(statusLine: "在岗处理：\(String(prompt.prefix(20)))")
        missionTitle = "灵枢在岗"
        appendTrace(kind: .runtime, actor: "灵枢", title: "在岗接令", detail: String(prompt.prefix(40)))
        // 在岗会话跨回合复用同一记录:记下本回合开始前的产出物数,验收门只看本回合**新增**(否则"演示/答疑"会被旧PPT误拖进验收)。
        let baseline = currentArtifactCount(recordID)
        // **在岗答复流式(2026-06-23,提升流畅性)**:建一个实时流式气泡,模型正文增量边到边逐字上屏(+按句早读 TTS),
        // 不再整轮跑完才一次性回灌。多步循环里工具往返之间的停顿仍在(可接受),但有文字进度=不再"卡住很多次"。
        let streamBubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true, taskRecordID: recordID)
        chatMessages.append(streamBubble)
        standingStreamingBubbleID = streamBubble.id
        let bubbleID = streamBubble.id
        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value   // 单线程:等被取消的上一条回合真停下(在回合边界退出,历史良构),新回合才接手
            guard let self, !Task.isCancelled else { return }
            await session.setTextDeltaSink { [weak self] delta in
                await MainActor.run { self?.appendStreamingBubbleText(delta, to: bubbleID) }
            }
            let initial = await session.resume(sentText ?? prompt)
            // 常驻在岗路径关掉"回复文本声称产文件"的验收触发(trustReplyClaim:false):在岗轻量/对话/演示回合
            // 重活都派发给隔离 session 各自验收、自己几乎不直接产交付物,其回复一提到既有文件就误进验收→空转停滞("讲解完卡处理中")。
            let result = await self.verifyAndContinue(session: session, result: initial, userRequest: prompt, taskRecordID: recordID, artifactBaseline: baseline, trustReplyClaim: false)
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID)
        }
    }

    /// 确定性退出演示:停批量 + 掐 TTS + 关预览(抑制重弹)+ 停在飞回合 + 出声确认。不靠大脑(它常口头答应却不真关)。
    /// 出声确认走 chatMessages 追加(根视图 speakLatestReplyIfNeeded 念全文,自主模式主人听得到);保持在岗待命。
    private func exitPresentationDeterministically(prompt: String) -> String {
        batchInterruptRequested = true                                            // run_steps 批量在下一步边界停
        interruptSpeechOutput?()                                                  // 立刻掐当前 TTS
        previewController.suppressAutoReopenUntil = Date().addingTimeInterval(5)  // 5s 内拒绝任何 open/进全屏(防重弹)
        _ = previewController.close()                                             // 关演示窗(幂等,isPresented=false)
        autonomousRunTask?.cancel(); autonomousRunTask = nil                       // 停在飞的演示回合(若还在跑批量)
        appendTrace(kind: .system, actor: "灵枢", title: "退出演示", detail: String(prompt.prefix(30)))
        lingShuControlLog("flow/exit-present: 确定性退出演示 cmd「\(prompt.prefix(20))」")
        let ack = "好的,演示已退出,我在岗待命,有需要随时说。"
        chatMessages.append(.init(speaker: "灵枢", text: ack, isUser: false, taskRecordID: autonomousRunRecordID))
        missionStatus = "演示已退出,在岗待命。"
        enterCoreState(.standby, resetTimer: false)
        return ""
    }

    /// 预览已打开时的确定性前台控制:继续/下一页/上一页这类输入不是新任务,也不该再回模型重规划。
    /// 运行时直接推动当前可视材料,确保画面翻页与语音播放同步；复杂追问仍交给大脑。
    private func handleVisiblePresentationControl(prompt: String, recordID: String) {
        batchInterruptRequested = true
        interruptSpeechOutput?()
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.enterAutonomousRunningState(statusLine: "继续当前演示")
            self.missionTitle = "灵枢在岗"
            self.appendTrace(kind: .runtime, actor: "演示运行器", title: "前台控制", detail: String(prompt.prefix(40)))

            if LingShuInteractionFulfillment.isPreviousPageCommand(prompt) {
                await self.speakCurrentPreviewPage(after: self.previewController.prev(), recordID: recordID)
            } else if LingShuInteractionFulfillment.isNextPageCommand(prompt),
                      !LingShuInteractionFulfillment.isContinuePresentationCommand(prompt) {
                await self.speakCurrentPreviewPage(after: self.previewController.next(), recordID: recordID)
            } else {
                await self.continuePreviewPresentationFromCurrentPage(recordID: recordID)
            }

            guard !Task.isCancelled else { return }
            self.autonomousRunTask = nil
            self.enterCoreState(.standby, resetTimer: false)
            self.missionStatus = "当前演示段落已完成,仍在岗。"
        }
    }

    func continuePreviewPresentationFromCurrentPage(recordID: String) async {
        guard previewController.isPresented else { return }
        if !previewController.slideshow {
            let slide = previewController.setSlideshow(true)
            appendTaskRecordMessage(recordID, actor: "演示运行器", role: "进入全屏", kind: .agent, text: slide)
        }

        if previewController.isHTML {
            await speakCurrentPreviewPage(after: "继续当前网页预览。", recordID: recordID)
            return
        }

        let total = max(1, previewController.pageCount)
        while previewController.pageIndex < total {
            if Task.isCancelled || consumeBatchInterrupt() { return }
            await speakCurrentPreviewPage(after: nil, recordID: recordID)
            if Task.isCancelled || consumeBatchInterrupt() { return }
            if previewController.pageIndex >= total - 1 { break }
            let moved = previewController.next()
            appendTaskRecordMessage(recordID, actor: "演示运行器", role: "翻页", kind: .agent, text: moved)
            await Task.yield()
        }
        let done = "这一段我已经讲完了。需要我继续答疑、回到某一页，还是收尾？"
        voiceManager?.speak(done)
        recordSpokenLine(done)
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "演示停顿", kind: .result, text: done)
        await voiceManager?.awaitPlaybackDone()
    }

    func speakCurrentPreviewPage(after actionResult: String?, recordID: String) async {
        if let actionResult {
            appendTaskRecordMessage(recordID, actor: "演示运行器", role: "翻页", kind: .agent, text: actionResult)
        }
        let title = previewController.title
        let page = previewController.displayedPageNumber
        let total = previewController.pageCount > 0 ? previewController.pageCount : nil
        let pageText = previewController.isHTML ? "" : previewController.pageText(max(0, page - 1))
        let line = LingShuInteractionFulfillment.pageNarration(title: title, pageNumber: page, totalPages: total, pageText: pageText)
        voiceManager?.speak(line)
        recordSpokenLine(line)
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "逐页讲解", kind: .result, text: line)
        await voiceManager?.awaitPlaybackDone()
    }

    /// 纯唤醒词("灵枢")打断:**真停掉在飞的处理**(主回合 + 自主/在岗回合),回到聆听。保持在岗(不下岗)。
    /// 修"喊灵枢有'叮'声却打不断理解中"(2026-06-20):原纯唤醒打断只置 `batchInterruptRequested`,而那只停 run_steps 批量;
    /// screen_capture/scroll 这类**模型调用循环**靠 `Task.isCancelled` 才退 → 没 cancel 任务就停不下来。这里把在飞 Task 真取消。
    func interruptInFlightForWakeWord() {
        activeAgentTurnTask?.cancel(); activeAgentTurnTask = nil
        autonomousRunTask?.cancel(); autonomousRunTask = nil
        isModelReplying = false
        batchInterruptRequested = true     // 同时停 run_steps 批量(演示翻页)
        setLoopPhase(.idle)
        missionTitle = "灵枢在岗"
        lingShuControlLog("voice/barge: 纯唤醒打断·已 cancel 在飞回合(主+自主),回到聆听")
    }

    /// 「执行中被打断 → 放弃当前工作、起新回合」时给大脑的措辞(单线程语义):让它据会话上下文决定继续还是改做新指示。
    func interruptedResumeFraming(_ prompt: String) -> String {
        """
        [主人在你执行中打断了你 · 最高优先级] 新指示:\(prompt)
        你刚才手头的事**已经停下**了。先看这条新指示:
        · 若是"继续/接着讲/接着做"这类——回到刚才的进度,**从断点接着做**(会话历史里有你刚才在做什么、做到哪)。
        · 否则——**放下刚才的事**,按这条新指示来。
        不要把它当成把整件事从头重做。
        """
    }
}
