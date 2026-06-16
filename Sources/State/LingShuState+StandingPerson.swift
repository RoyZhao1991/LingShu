import Foundation

/// 常驻灵枢（独立运行的新形态，用户定调 2026-06-16）。
/// 取向：独立运行模式启动后，灵枢就是一个**能听、能说、能思考、能动手的"人"**——
/// 不再要求预先写一个一次性「目标」。上岗后由对话/语音自然驱动它行动；执行带其权限级与全套四肢。
/// 与目标驱动的独立运行（prepareAutonomousRun，仍保留给"进入独立运行模式 + 一句话目标"的命令路径）解耦。
@MainActor
extension LingShuState {

    /// 常驻灵枢在岗中：无单一目标（空 objective）且执行会话仍在（可接续）。运行/暂停均算在岗。
    var isStandingPersonOnDuty: Bool {
        autonomousRun.phase != .idle
            && autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && autonomousSessionHolder != nil
    }

    /// 让灵枢「上岗」成为常驻灵枢：不需要预设目标——环境自检通过即直接上岗（能听/能说/能思考/能动手），
    /// 之后由对话/语音自然驱动。环境有阻断项则不上岗，提示先处理。
    func goLiveAsStandingPerson() {
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

    /// 灵枢在岗时，用户对话/语音 → 直接喂给在岗的执行会话（带其权限级与四肢），让它真去做，
    /// 而不是另起一个无权限的主回合。返回非 nil 表示已接管本轮输入；真实回复由 finishAutonomousRun 的在岗分支回灌。
    ///
    /// **通用 LOOP 人机讨论（不是 PPT 定制）**：
    /// - 在岗会话**此刻正在跑一条回合**（演示/连续任务进行中）→ 把这句当作「中途插话」**注入正在跑的那条脑回路**
    ///   （`injectCorrection`，回合边界安全采纳）——不打断、不重启:大脑先口头回应,再按需接着从当前进度推进。
    ///   这套机制对任何长回合通用（演示 PPT、开会、跑长任务……),配合麦克风打断 TTS = 随时插入讨论再续。
    /// - 在岗会话**空闲**（上一段已收尾）→ 起一条新回合续跑（resume）。
    func handleStandingPersonInputIfNeeded(prompt: String, taskRecordID: String?) -> String? {
        guard isStandingPersonOnDuty, let session = autonomousSessionHolder else { return nil }
        let recordID = autonomousRunRecordID ?? createTaskExecutionRecord(for: "灵枢在岗")
        autonomousRunRecordID = recordID
        appendTaskRecordMessage(recordID, actor: "主人", role: "指令", kind: .core, text: prompt)

        // 正在跑长回合 → 中途插话注入(通用 LOOP),不重启那条脑回路。
        if autonomousRunTask != nil {
            appendTrace(kind: .system, actor: "灵枢", title: "在岗插话", detail: String(prompt.prefix(40)))
            missionStatus = "收到插话，正在回应…"
            Task { @MainActor [weak self] in
                guard let self else { return }
                let caught = await session.injectCorrection(self.liveInterjectionFraming(prompt))
                // 没接住(回合刚好收尾)→ 退回常规续跑,别把这句吞了。
                if !caught { self.resumeStandingSession(session: session, prompt: prompt, recordID: recordID) }
            }
            return ""
        }

        resumeStandingSession(session: session, prompt: prompt, recordID: recordID)
        return ""   // 已接管：真实回复由 finishAutonomousRun 的在岗分支回灌
    }

    /// 在岗空闲时起一条新回合续跑（与插话注入区分）。**不再前置感知态势**——
    /// 直接问的问题就干净地答(屏幕变化只静默监测,要看屏自己 screen_capture),避免"介绍一下你自己"被态势前缀污染成"在岗待命"。
    func resumeStandingSession(session: LingShuAgentSession, prompt: String, recordID: String) {
        enterAutonomousRunningState(statusLine: "在岗处理：\(String(prompt.prefix(20)))")
        missionTitle = "灵枢在岗"
        appendTrace(kind: .runtime, actor: "灵枢", title: "在岗接令", detail: String(prompt.prefix(40)))
        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let initial = await session.resume(prompt)
            let result = await self.verifyAndContinue(session: session, result: initial, userRequest: prompt, taskRecordID: recordID)
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID)
        }
    }

    /// 「主人中途插话」的注入措辞（通用 LOOP）：先口头回应,该停就停、该改就改;答完若在连续任务/演示中,
    /// 简短问一句是否继续,再**从当前进度**接着推进(断点续演,不重头)。
    func liveInterjectionFraming(_ prompt: String) -> String {
        """
        [主人中途插话/提问 · 最高优先级] \(prompt)
        先用一两句话**口头回应**（用 `speak` 出声）：是提问就当场答清楚；是让你停下/换个方式就照做。
        回应完，如果你正在做演示或连续任务：用一句话问主人「要继续吗」，得到肯定再**从当前这一页/这一步接着往下**（断点续演，别从头来）；如果主人让停就停下待命。
        不要把这次插话当成重新开始整件事。
        """
    }
}
