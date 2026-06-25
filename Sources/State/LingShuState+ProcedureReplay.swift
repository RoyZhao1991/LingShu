import Foundation

/// **Record & Replay — replay 执行器(③)**:用户「用某技能 + 新参数」→ 确定性匹配技能、抽参,
/// 把步骤里的 {{参数}} 填好,再用**计算机控制四肢**(screen_capture/list_ui_elements/click/type_text…)**按意图逐步执行**
/// (找元素不靠坐标,UI 改版也能干)。碰钱/不可逆先停下问。限时,绝不无限挂。
@MainActor
extension LingShuState {

    /// 「用X技能…」replay 请求 → 确定性匹配 + 执行。返回 true=已接管。
    func handleProcedureReplayIfNeeded(_ prompt: String) -> Bool {
        guard procedureRecording == nil else { return false }                    // 录制中不抢
        let skills = LingShuProcedureSkillRouter.loadProcedures()
        guard !skills.isEmpty, let match = LingShuProcedureSkillRouter.matchReplay(prompt, skills: skills) else { return false }
        chatMessages.append(.init(speaker: "你", text: prompt, isUser: true))
        // 缺参:先问清再跑(别拿占位符瞎操作)。
        let missing = match.skill.missingParameters(given: match.params)
        if !missing.isEmpty {
            let hints = match.skill.parameters.filter { missing.contains($0.name) }
                .map { $0.example.isEmpty ? $0.name : "\($0.name)(如\($0.example))" }.joined(separator: "、")
            speakAndChat("用「\(match.skill.title)」还差这些参数:\(hints)。你一次说全,比如『用\(match.skill.triggers.first ?? match.skill.title),\(hints)』,我就跑。")
            return true
        }
        if let gate = computerControlGate(requiresAccessibility: true) {
            speakAndChat("要替你跑这个技能我得能操作界面。\(gate)")
            return true
        }
        replayProcedure(skill: match.skill, params: match.params)
        return true
    }

    /// 执行一个过程技能:挂计算机控制工具、强脑、按解析好的步骤逐步操作。限时 5 分钟。
    func replayProcedure(skill: LingShuProcedureSkill, params: [String: String]) {
        let steps = skill.resolvedSteps(params)
        let stepText = steps.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let paramEcho = params.map { "\($0)=\($1)" }.joined(separator: "、")
        speakAndChat("好,我用「\(skill.title)」替你跑\(paramEcho.isEmpty ? "" : "(\(paramEcho))")。我会逐步操作,碰到要花钱或不可逆的会先停下问你。")

        let appLine = skill.appHint.map { "主要在「\($0)」里操作。" } ?? ""
        let objective = """
        你现在用计算机控制四肢,**严格按下面步骤逐步操作一个已学会的技能**(不是写代码,是真在界面上点/填)。\(appLine)
        每一步:**先 screen_capture 或 list_ui_elements 看清当前界面**,再用 click / double_click / type_text / press_key / scroll 操作;**按意图找元素**(界面位置可能和当初录制时不同,认按钮/字段的名字,不靠死坐标)。
        **安全红线**:碰到要花钱、提交订单/付款、删除、发送对外消息、任何不可逆动作,**先停下用 ask_user 跟我确认再做**,绝不擅自提交。
        每步操作前用一句话说你在做什么。全部做完,简短回一句结果(成功/卡在哪)。

        要执行的步骤(参数已填好):
        \(stepText)
        """

        procedureReplayTask?.cancel()
        procedureReplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let session = self.makeAgentSession(
                id: "replay-\(UUID().uuidString.prefix(5))",
                system: objective,
                initialMessages: [],
                tools: self.computerControlTools(),
                model: self.makeAgentModelAdapter(),
                maxTurns: 40,
                maxHistoryMessages: 40,
                recordIDProvider: { nil }
            )
            // 限时 5 分钟:超时取消,绝不无限挂。
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                self?.procedureReplayTask?.cancel()
            }
            let result = await self.driveAgentDelivery(session: session, prompt: "开始按步骤执行这个技能。", taskRecordID: nil)
            watchdog.cancel()
            guard !Task.isCancelled else { self.speakAndChat("这次执行我中途停了(超时或被取消)。"); return }
            switch result {
            case .completed(let text):
                self.speakAndChat("「\(skill.title)」跑完了。\(text.prefix(120))")
            case .blocked(let q):
                self.speakAndChat(q)   // 需要我确认/补充(如碰到付款)
            case .maxTurnsReached(let last):
                self.speakAndChat("步骤有点多我没全跑完,跑到:\(last.prefix(100))。要不要我接着来?")
            case .interrupted(let reason):
                self.speakAndChat("执行中断了:\(reason)。")
            }
        }
    }
}
