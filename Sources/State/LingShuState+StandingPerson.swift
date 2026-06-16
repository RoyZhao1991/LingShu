import Foundation

/// 常驻数字人（独立运行的新形态，用户定调 2026-06-16）。
/// 取向：独立运行模式启动后，灵枢就是一个**能听、能说、能思考、能动手的"人"**——
/// 不再要求预先写一个一次性「目标」。上岗后由对话/语音自然驱动它行动；执行带其权限级与全套四肢。
/// 与目标驱动的独立运行（prepareAutonomousRun，仍保留给"进入独立运行模式 + 一句话目标"的命令路径）解耦。
@MainActor
extension LingShuState {

    /// 常驻数字人在岗中：无单一目标（空 objective）且执行会话仍在（可接续）。运行/暂停均算在岗。
    var isStandingPersonOnDuty: Bool {
        autonomousRun.phase != .idle
            && autonomousRun.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && autonomousSessionHolder != nil
    }

    /// 让灵枢「上岗」成为常驻数字人：不需要预设目标——环境自检通过即直接上岗（能听/能说/能思考/能动手），
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
            objective: "",                       // 空目标 = 常驻数字人（不是某个一次性任务）
            phase: canRun ? .ready : .blocked,
            permissionLevel: autonomousPermissionLevel,
            environment: environment,
            selfCheck: nil,
            runbook: nil,
            statusLine: canRun ? "数字人准备上岗。" : "环境存在阻断项，请先处理后再上岗。",
            startedAt: nil,
            updatedAt: now
        )
        guard canRun else {
            missionTitle = "数字人上岗受阻"
            missionStatus = environment.summaryLine
            appendTrace(kind: .warning, actor: "数字人", title: "上岗受阻", detail: environment.summaryLine)
            return
        }
        appendTrace(kind: .system, actor: "数字人", title: "环境自检", detail: environment.summaryLine)
        authorizeAutonomousRun()
    }

    /// 常驻数字人在岗时，用户对话/语音 → 直接喂给在岗的执行会话（带其权限级与四肢），让它真去做，
    /// 而不是另起一个无权限的主回合。返回非 nil 表示已接管本轮输入；真实回复由 finishAutonomousRun 的在岗分支回灌。
    func handleStandingPersonInputIfNeeded(prompt: String, taskRecordID: String?) -> String? {
        guard isStandingPersonOnDuty, let session = autonomousSessionHolder else { return nil }
        let recordID = autonomousRunRecordID ?? createTaskExecutionRecord(for: "数字人在岗")
        autonomousRunRecordID = recordID
        enterAutonomousRunningState(statusLine: "在岗处理：\(String(prompt.prefix(20)))")
        missionTitle = "数字人在岗"
        appendTaskRecordMessage(recordID, actor: "主人", role: "指令", kind: .core, text: prompt)
        appendTrace(kind: .runtime, actor: "数字人", title: "在岗接令", detail: String(prompt.prefix(40)))

        let previous = autonomousRunTask
        autonomousRunTask?.cancel()
        autonomousRunTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            // 把当前周期感知态势前置进指令,大脑接令时已"看到"当前屏幕(更快、连贯)。
            let framed = self.standingPromptWithPerception(prompt)
            let initial = await session.resume(framed)
            let result = await self.verifyAndContinue(session: session, result: initial, userRequest: prompt, taskRecordID: recordID)
            guard !Task.isCancelled else { return }
            self.finishAutonomousRun(result: result, recordID: recordID)
        }
        return ""   // 已接管：真实回复由 finishAutonomousRun 的在岗分支回灌
    }
}
