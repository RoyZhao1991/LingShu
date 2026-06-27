import Foundation

@MainActor
extension LingShuState {
    /// spawn_task:真模型据此自主派生并行隔离子会话(经编排器,后台真并行,账本回报)。
    func spawnTaskTool(adapter: LingShuGatewayAgentModel) -> LingShuAgentTool {
        let orchestrator = agentOrchestrator
        return LingShuAgentTool(
            name: "spawn_task",
            description: "为一个独立任务派生并行子任务(后台推进,完成/卡住会回报)。用于一句话里多个互不相关的目标。**同时最多 3 条子任务并行**,已满会被拒绝——届时请等其中一条完成再派,或在本会话顺序处理。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"objective\":{\"type\":\"string\",\"description\":\"该子任务要达成的自足目标\"}},\"required\":[\"objective\"]}"
        ) { [weak self] argumentsJSON in
            let objective = Self.jsonField(argumentsJSON, "objective") ?? argumentsJSON
            let conversationOnly = await MainActor.run { [weak self] in self?.isMinimalVoiceMode ?? false }
            if conversationOnly {
                return "当前是极简对话模式(纯对话),不派生子任务。请直接在本对话里简洁回答用户,不要拆子任务、不要写文件。"
            }

            let running = await orchestrator.runningCount()
            let cap = await orchestrator.capacity()
            guard running < cap else {
                return "⛔ 已有 \(running) 个子任务在并行运行(上限 \(cap) 条),本次未派生「\(objective)」。请等其中一条完成后再派生,或在本会话顺序处理该目标。"
            }

            let subID = "sub-\(UUID().uuidString.prefix(6))"
            let recordID = await MainActor.run { [weak self] () -> String? in
                guard let self else { return nil }
                let rid = self.createTaskExecutionRecord(for: objective)
                self.agentSubTaskRecords[subID] = rid
                return rid
            }

            // P1+P2:派生前先建记录、再前置认知(GoalSpec + 能力缺口分析)绑定记录,**再** spawnDetached——
            // 避免子任务先跑完而认知还没绑的竞态。已绑过则幂等跳过。
            if let recordID {
                await self?.bindPreflightCognition(request: objective, recordID: recordID)
            }

            let subTools = await MainActor.run { [weak self] () -> [LingShuAgentTool] in
                let policy = self?.dispatchedTaskExecutionPolicy ?? .standard
                let builtin = self?.agentBuiltinTools(recordIDProvider: { [weak self] in self?.agentSubTaskRecords[subID] }, executionPolicy: policy) ?? []
                let extras = self.map { me in [
                    me.searchTextTool(),
                    me.findImagesTool(),
                    me.acquireResourceTool(),
                    me.authorComponentTool(),
                    me.discoverSkillTool(),
                    me.discoverDevicesTool(),
                    me.peripheralsTool(),
                    me.labelPeripheralTool(),
                    me.askChoiceTool(),
                    me.askFormTool(),
                    me.updateTaskPlanTool(recordIDProvider: { [weak me] in me?.agentSubTaskRecords[subID] }),
                    me.reviewDesignTool(recordIDProvider: { [weak me] in me?.agentSubTaskRecords[subID] })
                ] } ?? []
                let bodyTools = self.map { [$0.speakTool(), $0.digitalHumanTool()] } ?? []
                let asyncTools = self.map { $0.backgroundWatchTools() + $0.scheduledTaskTools() } ?? []
                return builtin + [Self.timeTool(), Self.locationTool(), Self.askUserTool()] + (self.map { [$0.webSearchTool()] } ?? []) + bodyTools + extras + asyncTools
            }

            let sub: (any LingShuAgentSessioning)? = await MainActor.run { [weak self] in
                self?.makeAgentSession(
                    id: subID,
                    system: "你是子任务执行者,完成给定目标。**有产出物的必须用 write_file/run_command 真把文件落到工作目录并汇报路径,不要只口头说完成**;写代码必须真构建+运行不崩+测试全绿,跑崩了/报错是要修复的观测、不是交付;信息确实不足才调用 ask_user。",
                    tools: subTools,
                    model: adapter,
                    maxTurns: 80,
                    recordIDProvider: { [weak self] in self?.agentSubTaskRecords[subID] }
                )
            }
            guard let sub else { return "（执行环境已释放,本次未派生「\(objective)」。）" }

            let admitted = await orchestrator.spawnDetached(id: subID, objective: objective, session: sub)
            guard admitted else {
                if let recordID {
                    await MainActor.run { [weak self] in
                        self?.appendTaskRecordMessage(recordID, actor: "任务队列", role: "背压", kind: .warning, text: "子任务并发达到上限,本次未派生。")
                        self?.finishTaskRecord(recordID, status: .blocked, summary: "子任务并发达到上限,本次未派生。")
                        self?.agentSubTaskRecords[subID] = nil
                    }
                }
                return "⛔ 子任务并发刚好达到上限(\(cap) 条),本次未派生「\(objective)」。请稍后再派或顺序处理。"
            }
            return "已派生并行子任务[\(subID)]:\(objective)。它在后台推进,完成或卡住会汇报到账本。"
        }
    }
}
