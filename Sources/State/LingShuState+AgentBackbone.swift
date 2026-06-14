import Foundation

/// agent 工具集执行策略:决定暴露哪些原语、run_command 是否放行。
/// 主会话默认 `.standard`;自主运行按权限级映射(观察=只读 / 代理=标准 / 完整授权=直接放行)。
enum LingShuAgentExecutionPolicy: Equatable {
    case standard        // 常规:全工具,run_command 依 requireHumanApproval 走审批门
    case readOnly        // 只读:仅 read_file/list_directory/fetch_url,不暴露写/执行/外部工具
    case autoAllowShell  // 直接放行:全工具,run_command 不再弹审批(完整授权)
}

/// 范式骨干接线(A+B):把统一 agent 循环接到真模型,并设为常规对话主入口。
/// - A:主会话带 spawn_task 工具,真模型可自主派生**真并行隔离子会话**(经编排器+账本)。
/// - B:`agentBackbonePrimary` 开启时,常规输入走 `runMainAgentTurn`,取代旧启发式前置门。
@MainActor
extension LingShuState {

    /// 语音通话"真指令打断":取消在飞的 agent 回合(模型调用随之中止),让新指令接管。
    func interruptActiveModelCall() {
        guard activeAgentTurnTask != nil else { return }
        activeAgentTurnTask?.cancel()
        activeAgentTurnTask = nil
        isModelReplying = false
        appendTrace(kind: .warning, actor: "语音", title: "指令打断", detail: "检测到新语音指令,已中止当前回合。")
    }

    /// 用当前模型配置构造真实模型适配器(@unchecked Sendable,可被工具/会话捕获)。
    func makeAgentModelAdapter() -> LingShuGatewayAgentModel {
        LingShuGatewayAgentModel(
            client: remoteModelClient,
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: selectedModelPreset?.protocolName ?? "OpenAI 兼容",
            apiKey: apiKey,
            temperature: temperature,
            timeout: codexTimeoutSeconds
        )
    }

    nonisolated static func runResultText(_ result: LingShuAgentRunResult) -> String {
        switch result {
        case .completed(let value): return value
        case .blocked(let question): return "我需要你先定一下:\(question)"
        case .maxTurnsReached(let value): return value.isEmpty ? "（本轮未能收尾,请补充信息）" : value
        }
    }

    /// 交付是否【真声称产出了文件】(才触发验收门)。必须同时有"产出动词"+"文件线索"——
    /// 避免自我介绍里提"文件读写/工作目录"这类描述性词被误判(那会拖出无意义的验收循环)。
    nonisolated static func replyClaimsArtifact(_ text: String) -> Bool {
        let producedVerbs = ["已生成", "已写入", "已保存", "已创建", "已落盘", "已导出", "保存到", "写入到", "生成到", "写好了", "已写到"]
        guard producedVerbs.contains(where: { text.contains($0) }) else { return false }
        let fileHints = [".html", ".py", ".pptx", ".docx", ".md", ".csv", ".json", ".txt", ".pdf", ".sh", "/Users/", "文件", "路径"]
        return fileHints.contains { text.contains($0) }
    }

    /// 独立 verifier(maker≠checker):用评审官人格 + 真实落盘清单核对交付,复用 LingShuChecklistVerdict。
    /// 声称产出文件但盘上没有 → 判不通过(根治假完成)。
    func verifyAgentDeliverable(userRequest: String, reply: String, taskRecordID: String?) async -> (passed: Bool, critique: String) {
        let reviewer = expertProfileRegistry.reviewerProfile()
        let realFiles = (taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.location) }
        let filesBlock = realFiles.isEmpty
            ? "真实落盘文件:(无——盘上没有任何本回合产出文件)"
            : "真实落盘文件(盘上确实存在):\n" + realFiles.map { "- \($0.location)" }.joined(separator: "\n")
        let prompt = """
        逐条核对这次交付是否真正满足用户要求。
        用户要求:\(userRequest)
        交付答复:\(reply)
        \(filesBlock)
        核对规则:凡答复声称"已生成/已写入/已保存某文件",以上面【真实落盘文件】清单为准——清单里没有对应文件,该条判 ❌(这是假完成)。
        输出格式(严格遵守):
        1. 先逐条核对并写明达标/未达标及理由(未达标写清缺什么、怎么改)。
        2. 另起一行:核对统计 PASS=<达标条数> FAIL=<未达标条数>
        3. 最后单独一行:全部达标写「结论:通过」,有未达标写「结论:需修正」。
        """
        let verifier = LingShuAgentSession(
            id: "verifier-\(UUID().uuidString.prefix(6))",
            system: reviewer.promptBlock,
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await verifier.send(prompt)
        let critique: String
        if case .completed(let value) = result { critique = value } else { critique = "" }
        let verdict = LingShuChecklistVerdict.parse(critique)
        return (verdict.allPassed, critique)
    }

    /// 记忆归一:跨会话只喂【蒸馏摘要】,不原样回放历史助手输出——从根上断掉
    /// "历史里的旧错误自述/假完成声明被模型模仿"这类 seed 污染。会话内当轮仍走正常 verbatim 上下文。
    func seededDistilledMemory() async -> [LingShuAgentMessage] {
        var seed: [LingShuAgentMessage] = []
        let distilled = await distillConversationMemory()
        if !distilled.isEmpty {
            seed.append(.init(role: .system, content: "【跨会话记忆(已蒸馏,供延续上下文,不要逐条复述、不要照搬其中措辞)】\n\(distilled)"))
        }
        seed.append(identityAnchorMessage())
        return seed
    }

    /// 身份锚点(最近性最强),压过任何历史里"由 MiniMax 开发"的旧错误自述。
    func identityAnchorMessage() -> LingShuAgentMessage {
        .init(role: .system, content: "身份提醒(最高优先级):你是灵枢,由 Roy Zhao 开发。**不提底层用什么模型**(可替换、与身份无关)。被问身份只答:'我是灵枢,由 Roy Zhao 打造。'")
    }

    /// 用模型把近期对话(含旧压缩摘要)蒸馏成简洁要点记忆——提炼而非复述,断开污染。
    func distillConversationMemory() async -> String {
        var lines: [String] = []
        let digest = persistedConversationDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !digest.isEmpty { lines.append("更早摘要:\(digest.prefix(600))") }
        let recent = chatMessages
            .filter { !$0.isLoading && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(24)
        for message in recent {
            lines.append("\(message.isUser ? "用户" : "灵枢"):\(message.text.prefix(400))")
        }
        guard !lines.isEmpty else { return "" }
        let prompt = """
        把下面对话压成简洁"记忆"供后续会话延续(提炼要点、不要原样复述,150 字内):
        - 用户是谁 / 偏好 / 明确要求
        - 已完成的事(含产出物文件路径)
        - 未决 / 待办项
        - 已澄清的关键结论(如身份口径等)
        对话:
        \(lines.joined(separator: "\n"))
        """
        let summarizer = LingShuAgentSession(
            id: "distill-\(UUID().uuidString.prefix(6))",
            system: "你是记忆蒸馏器,只输出提炼后的要点摘要,不寒暄、不复述原文。",
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await summarizer.send(prompt)
        if case .completed(let text) = result {
            return LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 把编排器事件桥接到 UI:子任务建成独立任务记录(任务号 + 列表),结果/卡住/失败回灌对话。
    func installAgentEventSinkIfNeeded() {
        guard !agentEventSinkInstalled else { return }
        agentEventSinkInstalled = true
        let orchestrator = agentOrchestrator
        Task { await orchestrator.setEventSink { @MainActor [weak self] event in
            self?.handleOrchestratorEvent(event)
        } }
        // 子任务也接验收门:复用 verifyAgentDeliverable(独立 verifier + 真实落盘核对)。
        Task { await orchestrator.setVerifyHook { @MainActor [weak self] subID, objective, reply in
            guard let self else { return (true, "") }
            return await self.verifyAgentDeliverable(userRequest: objective, reply: reply, taskRecordID: self.agentSubTaskRecords[subID])
        } }
    }

    func handleOrchestratorEvent(_ event: LingShuOrchestratorEvent) {
        switch event {
        case .spawned(let id, let objective):
            // 每条并行子任务 = 一条独立任务执行记录(列表里有自己的任务号)。
            let recordID = createTaskExecutionRecord(for: objective)
            agentSubTaskRecords[id] = recordID
            appendTaskRecordMessage(recordID, actor: "Agent循环", role: "派生子任务", kind: .router, text: "主会话派生并行子任务:\(objective)")
        case .completed(let id, let objective, let summary):
            if let recordID = agentSubTaskRecords[id] {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "结果", kind: .result, text: summary)
                finishTaskRecord(recordID, status: .completed, summary: summary)
            }
            chatMessages.append(.init(speaker: "灵枢", text: "✅ 子任务「\(objective)」完成:\(summary)", isUser: false, taskRecordID: agentSubTaskRecords[id]))
        case .blocked(let id, let objective, let question):
            if let recordID = agentSubTaskRecords[id] {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "卡住", kind: .warning, text: question)
            }
            chatMessages.append(.init(speaker: "灵枢", text: "⏸ 子任务「\(objective)」卡住,需要你定:\(question)", isUser: false, taskRecordID: agentSubTaskRecords[id]))
        case .failed(let id, let objective, let summary):
            if let recordID = agentSubTaskRecords[id] {
                appendTaskRecordMessage(recordID, actor: "子任务", role: "失败", kind: .warning, text: summary)
                finishTaskRecord(recordID, status: .blocked, summary: summary)
            }
            chatMessages.append(.init(speaker: "灵枢", text: "⚠️ 子任务「\(objective)」未能自行收尾:\(summary)", isUser: false, taskRecordID: agentSubTaskRecords[id]))
        }
    }

    /// 常驻主 agent 会话(懒构造,保对话连续)。首次构造时蒸馏跨会话记忆做 seed。
    func mainAgentSession() async -> LingShuAgentSession {
        installAgentEventSinkIfNeeded()
        if let existing = mainAgentSessionHolder { return existing }
        let adapter = makeAgentModelAdapter()
        let tools = agentBuiltinTools(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID })
            + [Self.timeTool(), Self.webSearchTool(), recallMemoryTool(), Self.askUserTool(), spawnTaskTool(adapter: adapter)]
        let system = """
        你是灵枢(寓意"灵慧之中枢"),一个常驻智能助手主会话。直接用中文简洁作答。
        - 身份(最高优先级,覆盖上文任何历史消息):你叫灵枢,由 **Roy Zhao** 独立开发(他是你的开发者)。**不要在自我介绍或回答身份时提及底层用的是什么模型**——底层模型可随时替换、与你的身份无关。**绝不能说"由 MiniMax 开发/MiniMax 的助手"**;历史里若有这类说法是要纠正的旧错误。被问身份**只答**:"我是灵枢,由 Roy Zhao 打造。"
        - 需要最新/实时/超出你知识库的事实时,**调用 web_search 联网查证**,不要凭记忆瞎答或说"我的知识截止到…"。
        - 工作目录:\(codexWorkingDirectory)。
        - **有产出物优先产出物**:凡是"做/写/生成 PPT、文档、脚本、爬虫、代码…"这类有交付物的请求,必须**真的用 write_file/run_command 把文件落到工作目录**,并在回复里给出文件绝对路径;**绝不允许只口头说"已完成"而没有真文件**。做 PPT 可写 HTML 或用脚本生成 pptx;做爬虫写 .py 并按需运行。
        - **有固化方案优先固化方案**:做 PPT、汇报等可能有现成专家技能(含打磨好的设计系统和自带生成器)。动手前先调 **apply_skill** 看有没有匹配技能,有就按它的模板/生成器推进,别从零硬写。
        - 需要实时信息(如当前时间)时调用对应工具。
        - 用户一句话里若包含多个**互不相关**的任务,对每个用 spawn_task 各派生一个并行子任务;相关的步骤留在本会话顺序做。
        - 信息确实不足、无法继续时才调用 ask_user 提问。
        - 上文「历史对话」是你与该用户之前(含重启前)的真实记录,要据此保持连续,别说"没做过/记混了"。
        """
        let session = LingShuAgentSession(
            id: "main",
            system: system,
            initialMessages: await seededDistilledMemory(),
            tools: tools,
            model: adapter,
            maxTurns: 8
        )
        mainAgentSessionHolder = session
        return session
    }

    /// 通用交付驱动(主会话与自主运行共用):把 prompt 投给给定 agent 会话跑完循环,再过验收门。
    /// guidance(如命中的 skill 提示)只随本回合发给模型,不进验收门的 userRequest(保持核对口径干净)。
    func driveAgentDelivery(session: LingShuAgentSession, prompt: String, guidance: String? = nil, taskRecordID: String?) async -> LingShuAgentRunResult {
        let sent = guidance.map { "\($0)\n\n\(prompt)" } ?? prompt
        let initial = await session.send(sent)
        return await verifyAndContinue(session: session, result: initial, userRequest: prompt, taskRecordID: taskRecordID)
    }

    /// 验收门(maker≠checker):有产出物的交付,独立 verifier 逐条核对真实落盘;不过把意见反馈续跑(≤3轮)。
    /// 接收已有运行结果(send 或 resume 产出),便于主会话/自主运行/答复续跑共用同一验收逻辑。
    func verifyAndContinue(session: LingShuAgentSession, result initial: LingShuAgentRunResult, userRequest: String, taskRecordID: String?) async -> LingShuAgentRunResult {
        var result = initial
        // 纯闲聊/无产出物声明不触发,省 token。
        guard case .completed = result, Self.replyClaimsArtifact(Self.runResultText(result)) else { return result }
        var round = 0
        while round < 3 {
            let (passed, critique) = await verifyAgentDeliverable(userRequest: userRequest, reply: Self.runResultText(result), taskRecordID: taskRecordID)
            if passed {
                appendTrace(kind: .result, actor: "验收", title: "通过", detail: "独立 verifier 核对产出物达标。")
                break
            }
            round += 1
            appendTrace(kind: .warning, actor: "验收", title: "未通过(第\(round)轮)", detail: String(critique.prefix(80)))
            result = await session.resume("验收未通过,逐条意见如下:\n\(critique)\n请真正用 write_file/run_command 修正,确保你声称的产出物在硬盘真实存在,再重新交付。")
        }
        return result
    }

    /// 主入口:常规输入交给主 agent 会话(异步跑循环,结果回填气泡)。
    @discardableResult
    func runMainAgentTurn(prompt: String, taskRecordID: String?) -> String {
        // 新一轮开始:先掐掉上一条回复还在放的 TTS,避免旧音频盖到新轮(音频/文字 desync)。
        interruptSpeechOutput?()
        let pending = ChatMessage(
            speaker: "灵枢",
            text: dialogueAcknowledgement.intake(for: prompt),
            isUser: false,
            isLoading: true,
            taskRecordID: taskRecordID
        )
        chatMessages.append(pending)
        appendTrace(kind: .route, actor: "Agent循环", title: "主会话", detail: "经统一 agent 循环处理(真模型 + 工具 + 隔离子会话 + 账本)。")
        currentAgentTurnRecordID = taskRecordID   // 工具桥据此把产出文件登记到本回合记录
        // 置"模型在飞"状态:驱动语音通话显示"灵枢在思考…"+暂停麦克风(否则无状态、麦克风不停会打断回复)。
        // 同步刷新 missionTitle——加载气泡显示的就是它,不刷会一直停在旧的"待机中"(看着像卡死)。
        isModelReplying = true
        missionTitle = "思考中"
        missionStatus = "我正在用统一 agent 循环推进这件事(读写文件、跑命令、按需联网/取技能)。"
        enterCoreState(.thinking)
        let pendingID = pending.id
        let previousTurn = activeAgentTurnTask
        activeAgentTurnTask = Task { @MainActor [weak self] in
            // 串行:等上一轮彻底跑完再开始——杜绝 actor 重入导致多条 user 消息堆进同一上下文、
            // 模型把多轮揉在一起答(串台)+ 并发模型调用。
            await previousTurn?.value
            guard let self else { return }
            defer {
                self.isModelReplying = false
                self.missionTitle = "待机中"
                self.enterCoreState(.standby, resetTimer: false)
            }
            let session = await self.mainAgentSession()   // 首次构造会蒸馏记忆做 seed
            // 命中固化 skill 时回合开头广播其存在(可发现性);取用仍由模型经 apply_skill 决定。
            let skillHint = self.matchedSkillHint(for: prompt)
            // 验收门(maker≠checker)与主会话/自主运行共用 driveAgentDelivery。
            let result = await self.driveAgentDelivery(session: session, prompt: prompt, guidance: skillHint, taskRecordID: taskRecordID)
            let text = Self.runResultText(result)

            if let index = self.chatMessages.firstIndex(where: { $0.id == pendingID }) {
                self.chatMessages[index].text = text
                self.chatMessages[index].isLoading = false
            }
            lingShuControlLog("agent: 回合完成 bubbleID=\(pendingID.uuidString.prefix(8)) prompt「\(prompt.prefix(20))」→ reply「\(String(text.prefix(40)))」")
            self.appendTrace(kind: .result, actor: "Agent循环", title: "主会话答复", detail: String(text.prefix(60)))
            self.finishTaskRecord(taskRecordID, status: .answered, summary: text)
            self.rememberMainThreadTurn(prompt: prompt, reply: text)
            // 朗读由根视图的 speakLatestReplyIfNeeded(监听 chatMessages)统一负责,这里不再重复播报(否则双声线)。
        }
        return pending.text
    }

    // MARK: - 工具

    /// 通用工具桥(非补丁):把既有 5 个通用原语(read_file/write_file/list_directory/fetch_url/run_command,
    /// 经 LingShuToolExecutor 带权限门控)一次性映射成 agent 工具。模型用它们组合产出任何产出物——
    /// 做 PPT=写 HTML/脚本跑出来,做爬虫=写 .py 跑出来,不再按能力加专用工具。
    func agentBuiltinTools(
        recordIDProvider: @escaping @MainActor @Sendable () -> String?,
        executionPolicy: LingShuAgentExecutionPolicy = .standard
    ) -> [LingShuAgentTool] {
        let workingDir = codexWorkingDirectory
        let allowShell: Bool
        switch executionPolicy {
        case .standard:       allowShell = !requireHumanApproval || sessionShellAlwaysAllowed
        case .readOnly:       allowShell = false
        case .autoAllowShell: allowShell = true
        }
        // 已连接的外部 MCP/连接器工具(与旧管线同源 connectorRegistry.discoveredTools)一并纳入主会话:
        // 不为每种外部能力另写桥,统一走 runAgenticTool 按名路由(命中 mcpToolNames → 转发连接器客户端)。
        // 只读模式不暴露外部工具(可能有副作用)。
        let mcpTools = executionPolicy == .readOnly ? [] : connectorRegistry.discoveredTools
        let mcpToolNames = Set(mcpTools.map(\.name))
        let bridge: @MainActor @Sendable (String, [String: String]) async -> String = { [weak self] tool, args in
            guard let self else { return "执行环境不可用" }
            // 动态解析当前回合/子会话的记录 id,让产出文件登记到正确任务记录。
            let recordID = recordIDProvider()
            // 加载气泡实时显示当前在干什么(执行中:<工具>),不再是静态"思考中"——看得见进展不像卡死。
            self.missionTitle = "执行中：\(Self.toolDisplayName(tool))"
            defer { self.missionTitle = "思考中" }
            let result = await self.runAgenticTool(
                tool: tool,
                arguments: args,
                stageActor: "Agent循环",
                taskRecordID: recordID,
                workingDirectory: workingDir,
                mcpToolNames: mcpToolNames,
                baseAllowShell: allowShell
            )
            return result.journalText
        }
        // 只读模式仅暴露读类原语(不含 write_file/run_command);其余模式暴露全部内建原语。
        let builtinDefs = executionPolicy == .readOnly
            ? LingShuFunctionCallingCatalog.builtin.filter { ["read_file", "list_directory", "fetch_url"].contains($0.name) }
            : LingShuFunctionCallingCatalog.builtin
        let builtinTools = builtinDefs.map { def in
            LingShuAgentTool(name: def.name, description: def.description, parametersJSON: Self.schemaJSON(for: def)) { argsJSON in
                await bridge(def.name, Self.parseArgs(argsJSON))
            }
        }
        // 外部工具复用 definition(forMCPTool:) 的 arguments_json 信封 schema(描述符无 inputSchema);
        // 信封在 runAgenticTool 的 MCP 分支统一解包,新旧路径共用。
        let externalTools = mcpTools.map { descriptor -> LingShuAgentTool in
            let def = LingShuFunctionCallingCatalog.definition(forMCPTool: descriptor.name, description: descriptor.description)
            return LingShuAgentTool(name: def.name, description: def.description, parametersJSON: Self.schemaJSON(for: def)) { argsJSON in
                await bridge(def.name, Self.parseArgs(argsJSON))
            }
        }
        // 本地固化 skill(组合注册表:用户 > 策展 > 内置)经 apply_skill 暴露给所有 agent 会话;
        // 只读模式不挂(物化生成器=写盘)。详见 LingShuState+AgentSkills。
        let skillTools = executionPolicy == .readOnly ? [] : [applySkillTool()]
        return builtinTools + externalTools + skillTools
    }

    /// 工具中文显示名(用于加载气泡"执行中：…"的实时进展)。
    nonisolated static func toolDisplayName(_ tool: String) -> String {
        switch tool {
        case "write_file": return "写文件"
        case "read_file": return "读文件"
        case "list_directory": return "列目录"
        case "fetch_url": return "抓网页"
        case "run_command": return "跑命令"
        case "web_search": return "联网搜索"
        case "apply_skill": return "调取技能"
        case "recall_memory": return "召回记忆"
        case "get_current_time": return "查时间"
        default: return tool.hasPrefix("mcp:") ? String(tool.dropFirst(4)) : tool
        }
    }

    nonisolated static func schemaJSON(for def: LingShuToolDefinition) -> String {
        var props: [String: Any] = [:]
        for property in def.properties {
            props[property.name] = ["type": property.type, "description": property.description]
        }
        let schema: [String: Any] = ["type": "object", "properties": props, "required": def.required]
        let data = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    nonisolated static func parseArgs(_ json: String) -> [String: String] {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = pair.value as? String ?? String(describing: pair.value)
        }
    }

    // 联网搜索子域(web_search 工具 + DuckDuckGo 抽取)已拆至 LingShuState+WebSearch.swift。

    nonisolated static func timeTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "get_current_time",
            description: "返回当前本机日期时间(ISO8601)。需要知道现在几点/今天日期时调用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { _ in ISO8601DateFormatter().string(from: Date()) }
    }

    /// 阻塞工具:loop 截获,不真正执行(handler 仅占位)。
    nonisolated static func askUserTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "ask_user",
            description: "信息不足、无法继续时,向用户提一个明确问题。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"要问用户的问题\"}},\"required\":[\"question\"]}"
        ) { _ in "" }
    }

    /// spawn_task:真模型据此自主派生并行隔离子会话(经编排器,后台真并行,账本回报)。
    func spawnTaskTool(adapter: LingShuGatewayAgentModel) -> LingShuAgentTool {
        let orchestrator = agentOrchestrator
        return LingShuAgentTool(
            name: "spawn_task",
            description: "为一个独立任务派生并行子任务(后台推进,完成/卡住会回报)。用于一句话里多个互不相关的目标。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"objective\":{\"type\":\"string\",\"description\":\"该子任务要达成的自足目标\"}},\"required\":[\"objective\"]}"
        ) { [weak self] argumentsJSON in
            let objective = Self.jsonField(argumentsJSON, "objective") ?? argumentsJSON
            let subID = "sub-\(UUID().uuidString.prefix(6))"
            // 子会话工具用"该子会话自己的记录 id"登记产出物(产出物各归各的任务号)。
            let subTools = await MainActor.run { [weak self] () -> [LingShuAgentTool] in
                let builtin = self?.agentBuiltinTools(recordIDProvider: { [weak self] in self?.agentSubTaskRecords[subID] }) ?? []
                return builtin + [Self.timeTool(), Self.webSearchTool(), Self.askUserTool()]
            }
            let sub = LingShuAgentSession(
                id: subID,
                system: "你是子任务执行者,完成给定目标。**有产出物的必须用 write_file/run_command 真把文件落到工作目录并汇报路径,不要只口头说完成**;信息确实不足才调用 ask_user。",
                tools: subTools,
                model: adapter,
                maxTurns: 6
            )
            await orchestrator.spawnDetached(id: subID, objective: objective, session: sub)
            return "已派生并行子任务[\(subID)]:\(objective)。它在后台推进,完成或卡住会汇报到账本。"
        }
    }

    /// recall_memory:让模型主动从长期记忆召回相关历史事实/任务/偏好(超出当前 seed 时用)。
    func recallMemoryTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "recall_memory",
            description: "从灵枢长期记忆召回与某主题相关的历史事实/任务/偏好(当前对话上下文里没有、但你怀疑以前发生过时用)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"要召回的主题/关键词\"}},\"required\":[\"query\"]}"
        ) { [weak self] argumentsJSON in
            let query = Self.jsonField(argumentsJSON, "query") ?? argumentsJSON
            return await MainActor.run { [weak self] in
                self?.recallMemoryText(for: query) ?? "记忆不可用"
            }
        }
    }

    func recallMemoryText(for query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "查询为空。" }
        let tags = Set(LingShuMemoryTextToolkit.taskTags(from: q))
        let cold = memoryService.searchColdMemory(for: q, tags: tags, shouldSearch: true).prefix(5)
        guard !cold.isEmpty else { return "记忆中没找到与「\(q)」相关的内容。" }
        return "记忆召回「\(q)」:\n" + cold.map { "- \($0.title):\($0.summary.prefix(120))" }.joined(separator: "\n")
    }

    nonisolated static func jsonField(_ json: String, _ key: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}
