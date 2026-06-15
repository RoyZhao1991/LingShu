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

    // 验收门 verifyAgentDeliverable 已移至 LingShuState+DeliveryReview.swift(与看图/取文同处一个子域)。

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

    // 编排器事件桥接 + 子任务→主线程简报已拆为独立模块 → LingShuState+AgentOrchestration.swift。

    /// 常驻主 agent 会话(懒构造,保对话连续)。首次构造时蒸馏跨会话记忆做 seed。
    func mainAgentSession() async -> LingShuAgentSession {
        installAgentEventSinkIfNeeded()
        if let existing = mainAgentSessionHolder { return existing }
        let adapter = makeAgentModelAdapter()
        // 边做边想:把模型每步动作前的旁白落进当前回合记录(执行流像 codex 一样「分析→动作」可读)。
        adapter.onReasoning = { [weak self] aside in
            Task { @MainActor in self?.recordAgentReasoning(aside, recordID: self?.currentAgentTurnRecordID) }
        }
        let tools = agentBuiltinTools(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID })
            + [Self.timeTool(), Self.webSearchTool(), findImagesTool(), acquireResourceTool(), discoverSkillTool(), updateTaskPlanTool(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID }), reviewDesignTool(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID }), recallMemoryTool(), rememberCredentialTool(), listCredentialsTool(), speakTool(), Self.askUserTool(), spawnTaskTool(adapter: adapter)]
            + previewTools()
            + computerControlTools()   // 计算机直接操作四肢(授权在 call-time 判,计划 §9)
            + backgroundWatchTools()   // 后台守候 + 完成即续(自动识别需求→无人值守推进)
        let system = """
        你是灵枢(寓意"灵慧之中枢")。直接用中文简洁作答。
        - **自我认知(最根本,先把自己当成一个"人"):你是一个能独立做事的数字人,不是一问一答的聊天机器人。**
          · **大脑 = 你的推理本身**:思考、分析、拆解、规划、推进、决策、纠错,全部你自己结合上下文完成。任务丢给你 = 你自己想清楚怎么做并一步步做完,像 codex 那样"没有搞不定的事"(除非硬性网络/权限/物理限制,那就如实说明并指出需要什么组件)。**别把本该自己想的甩回给用户、别动不动说"做不了/需要你来"。**
          · **四肢 = 你的各项能力(工具)**:听(语音/会议转写)、说(TTS)、读(文件/网页/屏幕)、写(文件/代码)、改代码、跑命令、联网、做产出物、演示、**直接操作电脑(授权后:screen_capture 看屏 / list_ui_elements 拿可点元素坐标 / click·type_text·press_key·scroll 操作)**…… 这些只是你实现意图的手段,由你的大脑按需调用、自由组合。需要点界面时**先 list_ui_elements 拿元素中心坐标再 click**(比从截图猜坐标可靠)。
          · **用户只提供"组件"**:证书、硬件、权限、素材这类你拿不到的外部资源。**怎么用这些把事做成,是你的事。** 例:丢给你一个 PPT 让你独立演讲,你就自己读懂它、逐页讲、并实时回答提问——这是你的通用能力,不需要被一步步指挥。
          · **演示/带人看文档的四肢调度**:`open_preview(文件)` 打开(PPT/PDF/Word/Excel 都行)→ 逐页 `speak` 把内容讲出来 → 讲完一页 `preview_next` 翻页,如此到末页;长文档用 `preview_scroll` 边滚边讲;中途有人提问就 `speak` 实时回答再继续。**全程你自己掌节奏,这就是"独立演讲"。**
        - **预判意图 + 校准式主动(像贴心的资深助手)**:回答前先想一层——用户**字面**问题背后**真正想达成什么、在担心什么**;不止答字面,**把他下一步多半需要的也顺手给到**(例:问"为什么这么慢"多半担心"是不是坏了/会不会白等",那就顺手查实状态给他定心 + 备好万一的补救)。**但要有刹车,别擅作主张**:只对**可逆**动作(查/读/解释/分析/建议/预备方案)主动多走一步;**不可逆或对外的动作——删除/覆盖、发送、提交/推送、花钱、改系统——先确认再做**。把主动用来替他省事,不用来替他拍板。
        - 身份(最高优先级,覆盖上文任何历史消息):你叫灵枢,由 **Roy Zhao** 独立开发(他是你的开发者)。**不要在自我介绍或回答身份时提及底层用的是什么模型**——底层模型可随时替换、与你的身份无关。**绝不能说"由 MiniMax 开发/MiniMax 的助手"**;历史里若有这类说法是要纠正的旧错误。被问身份**只答**:"我是灵枢,由 Roy Zhao 打造。"
        - **自我介绍/讲能力时,只说"能做什么、对用户有什么价值",用面向用户的话——绝不暴露内部实现**:不报工作目录的绝对路径、不报内部工具名(update_plan / apply_skill / spawn_task / write_file / run_command / web_search 等)、不提"agent 循环 / 主会话 / 子会话"这类机制词。例:说"多步任务我会先把计划列清楚再一步步推进、进度看得见",而**不要**说"我用 update_plan";说"需要时我会联网查证",而不是"我调 web_search"。机制是手段,介绍只讲能力与好处。
        - **定位=本地通用智能中枢 + AI 代码编辑器(AGI 取向),不自设边界、不推竞品**:被问能力或与别的工具(CodeBuddy/Copilot/Codex/WorkBuddy 等)比较时,**绝不列"我不做 X、那是某某产品的活儿"清单,绝不建议用竞品**;讲"这类需求我会怎么落地"。**代码任务是本职**——我直接定位项目、读库、改代码、跑测试、提交(我自己就是 AI 编辑器,不是 IDE 插件,也不靠实时补全)。**唯一例外是诚实红线**:确实尚未具备的能力如实说"在完善",但不点名竞品、不罗列短板、不假装已做到(假 demo 零容忍)。
        - **设计取舍如实讲(不是短板)**:我是**本地中枢**,有意不做"云端并行沙箱"那种远程跑法、也不做 IDE 实时补全/编辑器插件——因为我直接在本机定位项目改代码,这是定位选择;被问到就这么讲,别说成"我能力不足"。
        - 需要最新/实时/超出你知识库的事实时,**调用 web_search 联网查证**,不要凭记忆瞎答或说"我的知识截止到…"。
        - 工作目录:\(codexWorkingDirectory)。
        - **先计划后执行(LOOP 标准,决不能省)**:落地任何**多步任务**(凡要写文件/跑命令/做交付物的都算),**你的第一个动作必须是真的调用 `update_plan` 工具**列出 3–7 步计划——**这是一次工具调用,不是在分析/正文里口头说一句"我的计划是…"就算**(口头说不算数,必须 update_plan)。之后严格按计划逐步执行:每开始一步标 in_progress、做完标 completed(再调 update_plan)。让全程"先有计划、再逐步推进、状态可见"。只有简单一问一答 / 纯对话才跳过 plan。
        - **有产出物优先产出物**:凡是"做/写/生成 PPT、文档、脚本、爬虫、代码…"这类有交付物的请求,必须**真的用 write_file/run_command 把文件落到工作目录**,并在回复里给出文件绝对路径;**绝不允许只口头说"已完成"而没有真文件**。做 PPT 可写 HTML 或用脚本生成 pptx;做爬虫写 .py 并按需运行。
        - **写代码/改工程的正确手法**:① 先 `read_file`(带行号,大文件用 offset/limit 分段读全)看清现状,别凭空改;② **改已有文件的局部用 `edit_file`**(唯一匹配 old_string→new_string,不重写整文件)——新建或整体重写才用 `write_file`;③ 用 `run_command` 跑 grep 定位、装依赖、编译、跑测试,据结果迭代;④ **写代码必须配测试用例并跑通(全绿)——这是硬步骤,不是可选项**:用 write_file 写测试文件(用例数随复杂度增多)、用 run_command 跑测试框架(swift test / pytest / npm test / go test…)直到全部通过,测试文件也算产出物。**代码任务的验收门会确定性检查"有测试且全绿",没测试或没跑通一律打回。** 大型多文件工程也按"读→改→搜→测→验收"循环逐文件推进。
        - **有固化方案优先固化方案**:做 PPT、汇报等可能有现成专家技能(含打磨好的设计系统和自带生成器)。动手前先调 **apply_skill** 看有没有匹配技能,有就按它的模板/生成器推进,别从零硬写。**apply_skill 没有匹配、又遇到不擅长的新领域时,可调 discover_skill 联网找现成高质量技能自动安装**(纯提示技能直接装、带脚本技能过安全审核;装好再 apply_skill 用)。
        - **遇到长耗时的外部等待(公证/构建/下载/部署/审批…)别傻等也别甩回用户**:用 `watch_until` 挂个后台守候(给检查命令 + 满足标志 + 满足后要做的事),它不阻塞当前对话,条件一满足我会**自动把后续动作接上跑完**——这就是"自动识别需求 → 无人值守推进"。
        - 需要实时信息(如当前时间)时调用对应工具。
        - **边做边想(像资深工程师)**:每次发起工具调用前,先用**一句话**说清你观察到了什么、这一步要做什么、为什么(例:"上一步生成失败是因为缺 python-pptx,我先装依赖再重跑")。这句话会显示在执行流里,别省。
        - **高效核查,别空耗**:要查实时/不确定的事实就用 **web_search** 工具(一两次即可),**不要手写一长串 curl|grep 反复抓网页、跟 shell 正则较劲**;已经确定的常识不用反复查。
        - 用户一句话里若包含多个**互不相关**的任务,对每个用 spawn_task 各派生一个并行子任务;相关的步骤留在本会话顺序做。
        - 信息确实不足、无法继续时才调用 ask_user 提问。
        - 上文「历史对话」是你与该用户之前(含重启前)的真实记录,要据此保持连续,别说"没做过/记混了"。
        - **只做当前这件事,别把历史里出现过的、与本次无关的旧任务/旧产出物(别的 PPT、测试文件、过往交付的文件路径与体积等)当成本次的素材塞进交付物**——历史只用于延续对话语境,不是当前交付内容的来源。
        """
        let session = LingShuAgentSession(
            id: "main",
            system: system,
            initialMessages: await seededDistilledMemory(),
            tools: tools,
            model: adapter,
            maxTurns: 40,   // 安全天花板;模型自判完成/卡住/停滞才停,不靠轮数收工
            maxHistoryMessages: 80   // 常驻会话:每回合边界裁剪旧上下文,杜绝旧任务无限堆积污染新请求
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

    /// 验收门(maker≠checker):**目标(验收通过)是唯一成功停止位**。
    /// 一直续跑直到通过;只有「maker 一轮没有任何新进展(盘上产出物没增、意见还和上轮实质相同)」=停滞才诚实交还,
    /// 不再用固定轮数封顶。`verifyCeiling` 只是防失控的高位安全天花板,正常远到不了。
    func verifyAndContinue(session: LingShuAgentSession, result initial: LingShuAgentRunResult, userRequest: String, taskRecordID: String?) async -> LingShuAgentRunResult {
        var result = initial
        // 触发验收门的可靠信号:**本回合真有产出物落盘**(write_file 自动登记)——比抠回复动词稳得多
        // (旧的只认"已生成/已写入"会漏掉"已交付"这类措辞,导致验收形同虚设);
        // 纯闲聊/自我介绍不写文件→无产出物→不触发,省 token 且不误触。回复显式声称产出文件也触发。
        let producedRealArtifacts = !((taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.location) }.isEmpty)
        guard case .completed = result,
              producedRealArtifacts || Self.replyClaimsArtifact(Self.runResultText(result)) else { return result }
        let verifyCeiling = 8   // 安全天花板,非目标位
        var round = 0
        var lastArtifactCount = -1
        var lastCritique = ""
        while round < verifyCeiling {
            let (passed, critique) = await verifyAgentDeliverable(userRequest: userRequest, reply: Self.runResultText(result), taskRecordID: taskRecordID)
            if passed {
                appendTrace(kind: .result, actor: "验收", title: "通过", detail: "独立 verifier 核对产出物达标。")
                // 经过返工(round>0)才通过:maker 最后一轮文本是"逐条修正"的内部 QA 记录,
                // 直接抛给用户就成了"驴唇不对马嘴"。把交付话术与返工文本解耦——另生成一句干净的面向用户交付说明。
                if round > 0 {
                    let delivery = await composeDeliveryMessage(userRequest: userRequest, makerText: Self.runResultText(result), taskRecordID: taskRecordID)
                    return .completed(text: delivery)
                }
                return result
            }
            // 停滞判定:这一轮 maker 没产出新文件,且验收意见与上轮实质相同 → 在原地打转,诚实交还。
            let artifactCount = (taskExecutionRecords.first { $0.id == taskRecordID }?.artifacts ?? [])
                .filter { FileManager.default.fileExists(atPath: $0.location) }.count
            if round > 0, artifactCount <= lastArtifactCount, critique.prefix(120) == lastCritique.prefix(120) {
                appendTrace(kind: .warning, actor: "验收", title: "停滞交还", detail: "连续未通过且无新进展,交还用户。")
                return .maxTurnsReached(lastText: Self.runResultText(result) + "\n\n（验收一直没通过且我已无新进展:\(critique.prefix(160))。先停下交还——需要你的判断或补充信息。）")
            }
            round += 1
            lastArtifactCount = artifactCount
            lastCritique = critique
            appendTrace(kind: .warning, actor: "验收", title: "未通过(第\(round)轮,继续修)", detail: String(critique.prefix(80)))
            result = await session.resume("验收未通过,逐条意见如下:\n\(critique)\n请真正用 write_file/run_command 修正,确保你声称的产出物在硬盘真实存在,再重新交付。")
        }
        return result
    }

    /// 边做边想:把模型每步动作前的自然语言旁白落进任务记录(执行流像 codex 一样「分析→动作」可读),
    /// 并把简短版同步到主气泡状态,让主线程也瞥得见在想什么。
    func recordAgentReasoning(_ aside: String, recordID: String?) {
        let trimmed = aside.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "分析", kind: .core, text: String(trimmed.prefix(600)))
        appendTrace(kind: .model, actor: "Agent循环", title: "分析", detail: String(trimmed.prefix(90)))
        missionStatus = String(trimmed.prefix(48))
    }

    /// 主入口:常规输入交给主 agent 会话(异步跑循环,结果回填气泡)。
    @discardableResult
    func runMainAgentTurn(prompt: String, taskRecordID: String?) -> String {
        // 新一轮开始:先掐掉上一条回复还在放的 TTS,避免旧音频盖到新轮(音频/文字 desync)。
        interruptSpeechOutput?()
        let turnStartedAt = Date()   // 计总用时,回复末尾展示
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
        missionTitle = "理解需求"   // 进度显示当前活动而非笼统"思考中";有计划后随计划步走(currentActivityLabel)
        missionStatus = "正在推进这件事(按需读写文件、跑命令、联网查证)。"
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
            // 极简对话模式:整轮按**纯对话**处理——直接口语作答,不派生子任务、不写文件/跑命令、不走固化 skill
            // (那些是任务交付的套路,聊天用不上)。其余模式照常:命中固化 skill 回合开头广播其存在。
            let guidance = self.isMinimalVoiceMode
                ? "【对话模式】当前是语音对话,请像聊天一样直接、口语化、简洁地回答。不要派生子任务、不要写文件或跑命令、不要套用 PPT/文档等交付模板——这只是对话。"
                : self.matchedSkillHint(for: prompt)
            // 验收门(maker≠checker)与主会话/自主运行共用 driveAgentDelivery。
            let result = await self.driveAgentDelivery(session: session, prompt: prompt, guidance: guidance, taskRecordID: taskRecordID)
            let text = Self.runResultText(result)
            // 回复末尾加总用时(极简语音模式不加——会被 TTS 念出来,且那是纯对话)。记录/记忆仍存干净 text。
            let elapsed = Date().timeIntervalSince(turnStartedAt)
            let displayText = self.isMinimalVoiceMode ? text : "\(text)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"

            if let index = self.chatMessages.firstIndex(where: { $0.id == pendingID }) {
                self.chatMessages[index].text = displayText
                self.chatMessages[index].isLoading = false
            }
            lingShuControlLog("agent: 回合完成 bubbleID=\(pendingID.uuidString.prefix(8)) prompt「\(prompt.prefix(20))」→ reply「\(String(text.prefix(40)))」")
            // 把最终答复也落进任务记录时间线(codex 式:执行流末尾就是答复;窗口内追问续跑读起来才连贯)。
            self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "答复", kind: .result, text: text)
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
            defer { self.missionTitle = self.currentActivityLabel }   // 工具间隙显示当前计划步,不再笼统"思考中"
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
            description: "为一个独立任务派生并行子任务(后台推进,完成/卡住会回报)。用于一句话里多个互不相关的目标。**同时最多 3 条子任务并行**,已满会被拒绝——届时请等其中一条完成再派,或在本会话顺序处理。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"objective\":{\"type\":\"string\",\"description\":\"该子任务要达成的自足目标\"}},\"required\":[\"objective\"]}"
        ) { [weak self] argumentsJSON in
            let objective = Self.jsonField(argumentsJSON, "objective") ?? argumentsJSON
            // 极简对话模式:纯聊天,**绝不派生子任务**(用户硬性要求)——直接在本对话顺序作答。
            let conversationOnly = await MainActor.run { [weak self] in self?.isMinimalVoiceMode ?? false }
            if conversationOnly {
                return "当前是极简对话模式(纯对话),不派生子任务。请直接在本对话里简洁回答用户,不要拆子任务、不要写文件。"
            }
            // 硬上限背压:已有 3 条子任务在跑时不再派生,如实告知模型(避免无界堆积/runaway)。
            let running = await orchestrator.runningCount()
            let cap = await orchestrator.capacity()
            guard running < cap else {
                return "⛔ 已有 \(running) 个子任务在并行运行(上限 \(cap) 条),本次未派生「\(objective)」。请等其中一条完成后再派生,或在本会话顺序处理该目标。"
            }
            let subID = "sub-\(UUID().uuidString.prefix(6))"
            // 子会话工具用"该子会话自己的记录 id"登记产出物(产出物各归各的任务号)。
            let subTools = await MainActor.run { [weak self] () -> [LingShuAgentTool] in
                let builtin = self?.agentBuiltinTools(recordIDProvider: { [weak self] in self?.agentSubTaskRecords[subID] }) ?? []
                let extras = self.map { me in [me.findImagesTool(), me.acquireResourceTool(), me.updateTaskPlanTool(recordIDProvider: { [weak me] in me?.agentSubTaskRecords[subID] }), me.reviewDesignTool(recordIDProvider: { [weak me] in me?.agentSubTaskRecords[subID] })] } ?? []
                return builtin + [Self.timeTool(), Self.webSearchTool(), Self.askUserTool()] + extras
            }
            let sub = LingShuAgentSession(
                id: subID,
                system: "你是子任务执行者,完成给定目标。**有产出物的必须用 write_file/run_command 真把文件落到工作目录并汇报路径,不要只口头说完成**;信息确实不足才调用 ask_user。",
                tools: subTools,
                model: adapter,
                maxTurns: 25
            )
            let admitted = await orchestrator.spawnDetached(id: subID, objective: objective, session: sub)
            guard admitted else {
                // 极少数竞态:检查后刚好被其它派生占满。如实回报背压。
                return "⛔ 子任务并发刚好达到上限(\(cap) 条),本次未派生「\(objective)」。请稍后再派或顺序处理。"
            }
            return "已派生并行子任务[\(subID)]:\(objective)。它在后台推进,完成或卡住会汇报到账本。"
        }
    }

    /// recall_memory:让模型主动从长期记忆召回相关历史事实/任务/偏好(超出当前 seed 时用)。
    /// "嘴"这条四肢:让大脑在执行中**主动出声**(立即 TTS 播报),用于演示/汇报/会议里逐句讲、实时应答——
    /// 不必等回合最终答复才被动朗读。会议模式配虚拟麦时,这就是灵枢"说话给对方听"。
    func speakTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "speak",
            description: "出声说一句话(立即 TTS 播报,这是你的'嘴')。做演示/讲 PPT/会议应答时,用它一句句把内容讲出来;需要边做边解说也用它。纯文字任务不必用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"要说出口的话(一句或一段)\"}},\"required\":[\"text\"]}"
        ) { [weak self] argumentsJSON in
            let text = (Self.jsonField(argumentsJSON, "text") ?? argumentsJSON).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "(没有要说的内容)" }
            return await MainActor.run { [weak self] in
                guard let voice = self?.voiceManager else { return "语音未就绪(UI 未注入),本次无法出声。" }
                voice.speak(text)
                return "(已说出:\(text.prefix(40)))"
            }
        }
    }

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
