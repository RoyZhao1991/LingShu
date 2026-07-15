import Foundation

/// **Record & Replay — replay 执行器(③)**:用户「用某技能 + 新参数」→ 确定性匹配技能、抽参,
/// 把步骤里的 {{参数}} 填好,再用**原生 Computer Use**按应用快照和元素索引逐步执行
/// (找元素不靠坐标,UI 改版也能干)。碰钱/不可逆先停下问。限时,绝不无限挂。
@MainActor
extension LingShuState {

    /// 执行一个过程技能:挂计算机控制工具、强脑、按解析好的步骤逐步操作。限时 5 分钟。
    /// **入口只剩显式 `@<技能名>`**(2026-06-30 砍推断):缺参追问 + 计算机控制门已搬到声明式 `routePlugin` 的 proc 分支,
    /// 这里只负责"参数填好后真去操作"。原来的 `handleProcedureReplayIfNeeded`(matchReplay 关键词嗅探)已删。
    func replayProcedure(skill: LingShuProcedureSkill, params: [String: String]) {
        let steps = skill.resolvedSteps(params)
        let stepText = steps.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let paramEcho = params.map { "\($0)=\($1)" }.joined(separator: "、")
        speakAndChat("好,我用「\(skill.title)」替你跑\(paramEcho.isEmpty ? "" : "(\(paramEcho))")。我会逐步操作,碰到要花钱或不可逆的会先停下问你。")

        let appLine = skill.appHint.map { "主要在「\($0)」里操作。" } ?? ""
        let objective = """
        你现在用计算机控制四肢,**严格按下面步骤逐步操作一个已学会的技能**(不是写代码,是真在界面上点/填)。\(appLine)
        每一步的可靠做法:先 `computer_list_apps` 定位目标应用,再 `computer_get_state` 获取 snapshot_id 和元素 #index,用 `computer_click_element` / `computer_set_text` / `computer_press_key` / `computer_scroll_element` 操作。**每次动作后必须使用返回的新快照继续,并检查回读验证,不要把“已发出”当成成功。**只有目标应用不暴露辅助功能元素时才退回 screen_capture + 坐标工具。别反复观察不动手——看清后就推进下一步。
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
