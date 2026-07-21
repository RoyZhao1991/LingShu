import Foundation

private enum LingShuSpawnTaskToolDefinition {
    static let name = "spawn_task"
    static let description = "为一个独立任务派生并行子任务(后台推进,完成/卡住会回报)。用于一句话里多个互不相关的目标。**同时最多 3 条子任务并行**,已满会被拒绝——届时请等其中一条完成再派,或在本会话顺序处理。"
    static let parametersJSON = #"{"type":"object","properties":{"objective":{"type":"string","description":"该子任务要达成的自足目标"}},"required":["objective"]}"#
}

@MainActor
extension LingShuState {
    /// spawn_task:真模型据此自主派生并行隔离子会话(经编排器,后台真并行,账本回报)。
    func spawnTaskTool(adapter: LingShuGatewayAgentModel) -> LingShuAgentTool {
        let handler: @Sendable (String) async -> String = { [weak self] argumentsJSON in
            guard let self else {
                let objective = Self.jsonField(argumentsJSON, "objective") ?? argumentsJSON
                return "（执行环境已释放,本次未派生「\(objective)」。）"
            }
            return await self.executeSpawnTask(argumentsJSON: argumentsJSON, adapter: adapter)
        }

        return LingShuAgentTool(
            name: LingShuSpawnTaskToolDefinition.name,
            description: LingShuSpawnTaskToolDefinition.description,
            parametersJSON: LingShuSpawnTaskToolDefinition.parametersJSON,
            handler: handler
        )
    }

    private func executeSpawnTask(argumentsJSON: String, adapter: LingShuGatewayAgentModel) async -> String {
        let objective = Self.jsonField(argumentsJSON, "objective") ?? argumentsJSON
        if isMinimalVoiceMode {
            return "当前是极简对话模式(纯对话),不派生子任务。请直接在本对话里简洁回答用户,不要拆子任务、不要写文件。"
        }

        let running = await agentOrchestrator.runningCount()
        let cap = await agentOrchestrator.capacity()
        guard running < cap else {
            return "⛔ 已有 \(running) 个子任务在并行运行(上限 \(cap) 条),本次未派生「\(objective)」。请等其中一条完成后再派生,或在本会话顺序处理该目标。"
        }

        let subID = "sub-\(UUID().uuidString.prefix(6))"
        let recordID = createSpawnTaskRecord(subID: subID, objective: objective)
        guard await prepareSpawnTaskCognition(subID: subID, objective: objective, recordID: recordID) else {
            return "⛔ 子任务未启动:GoalSpec 重新生成耗尽,系统没有用默认目标降级执行。"
        }

        let workingDirectory = prepareSpawnTaskWorkingDirectory(subID: subID, objective: objective)
        let tools = makeSpawnTaskTools(subID: subID, workingDirectory: workingDirectory)
        let session = makeSpawnTaskSession(
            subID: subID,
            workingDirectory: workingDirectory,
            tools: tools,
            adapter: adapter
        )

        await prepareSubtaskArtifactDelta(subID: subID, recordID: recordID, workingDirectory: workingDirectory)
        let admitted = await agentOrchestrator.spawnDetached(id: subID, objective: objective, session: session)
        guard admitted else {
            finishRejectedSpawnTask(subID: subID, recordID: recordID)
            return "⛔ 子任务并发刚好达到上限(\(cap) 条),本次未派生「\(objective)」。请稍后再派或顺序处理。"
        }
        return "已派生并行子任务[\(subID)]:\(objective)。它在后台推进,完成或卡住会汇报到账本。"
    }

    private func createSpawnTaskRecord(subID: String, objective: String) -> String {
        let recordID = createTaskExecutionRecord(for: objective)
        agentSubTaskRecords[subID] = recordID
        return recordID
    }

    /// 派生前先建记录、再前置认知(GoalSpec + 能力缺口分析)绑定记录,再 spawnDetached。
    /// 避免子任务先跑完而认知还没绑定的竞态;已绑定时由下层幂等跳过。
    private func prepareSpawnTaskCognition(subID: String, objective: String, recordID: String) async -> Bool {
        let ready = await bindPreflightCognition(request: objective, recordID: recordID)
        if !ready {
            agentSubTaskRecords[subID] = nil
        }
        return ready
    }

    private func prepareSpawnTaskWorkingDirectory(subID: String, objective: String) -> String {
        let hint = Self.explicitWorkingDirectoryHint(in: objective)
        let directory = effectiveAgentWorkingDirectory(override: hint)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory),
            withIntermediateDirectories: true
        )
        agentSubTaskWorkingDirectories[subID] = directory
        return directory
    }

    private func makeSpawnTaskTools(subID: String, workingDirectory: String) -> [LingShuAgentTool] {
        let recordIDProvider: @MainActor @Sendable () -> String? = { [weak self] in
            self?.agentSubTaskRecords[subID]
        }
        let policy = dispatchedTaskExecutionPolicy
        let builtin = agentBuiltinTools(
            recordIDProvider: recordIDProvider,
            executionPolicy: policy,
            workingDirectoryOverride: workingDirectory
        )
        let standard = [Self.timeTool(), Self.locationTool(), Self.askUserTool(), webSearchTool()]
        let body = [speakTool(), digitalHumanTool()]
        let extras = [
            searchTextTool(),
            findImagesTool(),
            acquireResourceTool(),
            authorComponentTool(),
            discoverSkillTool(),
            discoverDevicesTool(),
            peripheralsTool(),
            labelPeripheralTool(),
            askChoiceTool(),
            askFormTool(),
            updateTaskPlanTool(recordIDProvider: recordIDProvider),
            reviewDesignTool(recordIDProvider: recordIDProvider)
        ]
        let asynchronous = backgroundWatchTools() + scheduledTaskTools()
        let agents = agentPluginTools(recordIDProvider: recordIDProvider, includeRegistration: false)
        return builtin + standard + body + extras + asynchronous + agents
    }

    private func makeSpawnTaskSession(
        subID: String,
        workingDirectory: String,
        tools: [LingShuAgentTool],
        adapter: LingShuGatewayAgentModel
    ) -> any LingShuAgentSessioning {
        let grounding = agentPluginGroundingText()
        let system = LingShuPersona.system(
            "现在你作为一条子任务线,独立完成给定目标。工作目录:\(workingDirectory)。**有产出物的必须用 write_file/run_command 真把文件落到工作目录并汇报路径,不要只口头说完成**;写代码必须真构建+运行不崩+测试全绿,跑崩了/报错是要修复的观测、不是交付;信息确实不足才调用 ask_user。\n\(grounding)"
        )
        if let embedded = makeEmbeddedLoopSession(
            id: subID,
            role: .maker,
            workingDirectory: workingDirectory,
            systemPrompt: system,
            recordID: agentSubTaskRecords[subID]
        ) {
            appendTaskRecordMessage(
                agentSubTaskRecords[subID],
                actor: "灵枢 Runtime",
                role: "Maker 路由",
                kind: .router,
                text: "本任务由常驻灵枢原生 Loop 创建独立 Maker 会话；完成后另建独立 Checker 会话验收。"
            )
            return embedded
        }
        appendTaskRecordMessage(
            agentSubTaskRecords[subID],
            actor: "灵枢 Runtime",
            role: "Maker 应急降级",
            kind: .warning,
            text: "灵枢原生 Loop Runtime 尚未就绪（\(LingShuEmbeddedGrokRuntime.shared.status.displayText(language: language))），本轮启用不可配置的应急兼容执行器。"
        )
        return makeAgentSession(
            id: subID,
            system: system,
            tools: tools,
            model: adapter,
            maxTurns: 80,
            recordIDProvider: { [weak self] in self?.agentSubTaskRecords[subID] }
        )
    }

    private func finishRejectedSpawnTask(subID: String, recordID: String) {
        let summary = "子任务并发达到上限,本次未派生。"
        appendTaskRecordMessage(recordID, actor: "任务队列", role: "背压", kind: .warning, text: summary)
        finishTaskRecord(recordID, status: .blocked, summary: summary)
        agentSubTaskRecords[subID] = nil
    }
}
