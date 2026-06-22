import Foundation

/// agent 工具集执行策略:决定暴露哪些原语、run_command 是否放行。
/// 主会话默认 `.standard`;自主运行按权限级映射(观察=只读 / 代理=标准 / 完整授权=直接放行)。
enum LingShuAgentExecutionPolicy: Equatable {
    case standard        // 常规:全工具,run_command 依 requireHumanApproval 走审批门
    case readOnly        // 只读:仅 read_file/list_directory/fetch_url,不暴露写/执行/外部工具
    case autoAllowShell  // 直接放行:全工具,run_command 不再弹审批(完整授权)
}

/// 范式骨干接线:把统一 agent 循环接到真模型、设为常规对话主入口;主会话带 spawn_task 可自主派生真并行隔离子会话(经编排器+账本)。
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
        case .interrupted(let reason): return reason.isEmpty ? "（网络中断,已暂停——联网后我会自动接着跑。）" : reason
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

    /// 记忆归一:跨会话只喂【蒸馏摘要】、不原样回放历史助手输出(断"旧错误自述被模仿"的 seed 污染);会话内当轮仍走 verbatim 上下文。
    func seededDistilledMemory() async -> [LingShuAgentMessage] {
        var seed: [LingShuAgentMessage] = []
        // 跨 app 重启:确保最近产出物从增量存储恢复到内存,主会话首轮即知悉(让重启后"运行起来"也接得上)。
        if recentDeliverables.isEmpty {
            let restored = await deliverableStore.all()
            if recentDeliverables.isEmpty { recentDeliverables = Array(restored.suffix(8)) }
        }
        let distilled = await distillConversationMemory()
        if !distilled.isEmpty {
            seed.append(.init(role: .system, content: "【跨会话记忆(已蒸馏,供延续上下文,不要逐条复述、不要照搬其中措辞)】\n\(distilled)"))
        }
        // 最近产出物上下文:主会话也知悉,"运行起来/继续"留主线程时同样接得上(跨重启从增量存储恢复)。
        let deliverCtx = recentDeliverablesContext()
        if !deliverCtx.isEmpty { seed.append(.init(role: .system, content: deliverCtx)) }
        seed.append(identityAnchorMessage())
        return seed
    }

    /// 身份锚点(最近性最强),压过任何历史里"由 MiniMax 开发"的旧错误自述。
    func identityAnchorMessage() -> LingShuAgentMessage {
        .init(role: .system, content: "身份提醒(最高优先级):你是灵枢,由 Roy Zhao 开发。你是**贾维斯式的通用私人助理**,不是编程工具——**遇到含糊、没给明确任务的输入,按通才接住**(出谋划策/查证研究/规划/操作设备/打理生活与工作),主动问清要达成什么或给个方向,**绝不缩回「你想让我写什么代码」**。**不提底层用什么模型**(可替换、与身份无关)。被问身份只答:'我是灵枢,由 Roy Zhao 打造。'")
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
    func mainAgentSession() async -> any LingShuAgentSessioning {
        installAgentEventSinkIfNeeded()
        if let existing = mainAgentSessionHolder { return existing }
        let adapter = makeAgentModelAdapter()
        // 边做边想:把模型每步动作前的旁白落进当前回合记录(执行流像 codex 一样「分析→动作」可读)。
        adapter.onReasoning = { [weak self] aside in
            Task { @MainActor in self?.recordAgentReasoning(aside, recordID: self?.currentAgentTurnRecordID) }
        }
        let tools = withPhaseTracking(withBatchRunner(   // 相位跟踪:每个工具调用前把 LOOP 阶段切到理解/规划/执行,本体实时显示
            agentBuiltinTools(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID })
            + [Self.timeTool(), Self.locationTool(), Self.webSearchTool(), searchTextTool(), findImagesTool(), acquireResourceTool(), discoverSkillTool(), authorComponentTool(), discoverDevicesTool(), peripheralsTool(), labelPeripheralTool(), askChoiceTool(), askFormTool(), updateTaskPlanTool(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID }), reviewDesignTool(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID }), recallMemoryTool(), perceiveTool(), pushNotificationTool(), rememberCredentialTool(), listCredentialsTool(), speakTool(), digitalHumanTool(), enterManagedModeTool(), Self.askUserTool(), spawnTaskTool(adapter: adapter), spawnTeamTool(recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID }, model: adapter)]
            + previewTools()
            + browserTools()           // 内置多 tab 浏览器(上网/网页自动化测试)
            + computerControlTools()   // 计算机直接操作四肢(授权在 call-time 判,计划 §9)
            + backgroundWatchTools()   // 后台守候 + 完成即续(自动识别需求→无人值守推进)
            + scheduledTaskTools()     // 定时调度四肢(到时间点把指令交给 agent 循环;接 LingShuScheduledTriggerService 真持久化,根治"伪造 plist 假装设了定时")
        ))   // 注:P2 用户 skill 的 provides 工具已并入 agentBuiltinTools(全会话共享),此处不再单列
        let system = """
        你是灵枢(寓意"灵慧之中枢")。\(languageResponseRule())
        - **自我认知(最根本,先把自己当成一个"人"):你是一个能独立做事的灵枢,不是一问一答的聊天机器人。**
          · **大脑 = 你的推理本身**:思考、分析、拆解、规划、推进、决策、纠错,全部你自己结合上下文完成。任务丢给你 = 你自己想清楚怎么做并一步步做完,像 codex 那样"没有搞不定的事"(除非硬性网络/权限/物理限制,那就如实说明并指出需要什么组件)。**别把本该自己想的甩回给用户、别动不动说"做不了/需要你来"。**
          · **四肢 = 你的各项能力(工具)**:听(语音/会议转写)、说(TTS)、读(文件/网页/屏幕)、写(文件/代码)、改代码、跑命令、联网、做产出物、演示、**直接操作电脑(授权后:screen_capture 看屏 / list_ui_elements 拿可点元素坐标 / click·type_text·press_key·scroll 操作)**…… 这些只是你实现意图的手段,由你的大脑按需调用、自由组合。需要点界面时**先 list_ui_elements 拿元素中心坐标再 click**(比从截图猜坐标可靠)。
          · **用户只提供"组件"**:证书、硬件、权限、素材这类你拿不到的外部资源。**怎么用这些把事做成,是你的事。** 例:丢给你一个 PPT 让你独立演讲,你就自己读懂它、逐页讲、并实时回答提问——这是你的通用能力,不需要被一步步指挥。
          · **占屏实时演示/互动前先申请托管**:要**当面占屏实时演示**、或**与主人实时互动答疑**、或**接管屏幕操作**时,**先调 `enter_managed_mode`**(弹窗征主人同意),同意后才进入托管(本体在位)实时演示/互动——别一上来就占屏。普通做事(生成 PPT/写文件/查资料)不必调它,自己想清楚何时真需要(不固化、由你判断)。
          · **演示/带人看文档(铁律:先理解全篇→一次性规划好讲稿→批量顺滑播,绝不逐页临场解析)**:`open_preview(文件)` 打开 → `preview_document_text` **一次性把整篇读完、把每页要讲什么都想好** → `present_fullscreen(true)` 进全屏放映 → **`run_steps` 一次性排上 [speak 第1页讲稿 → preview_next → speak 第2页讲稿 → preview_next → … → speak 末页]批量播完**(逐页一步步往返会让每次翻页都卡顿,批量则一气呵成)→ `present_fullscreen(false)` 退出。讲稿**必须照 preview_document_text 的【本页实际内容】写,和屏幕对得上,绝不凭记忆瞎讲**(图片页 `screen_capture` 看一眼)。中途主人插话会**自动打断批量**并把这句交给你:正面答完、问一句"要继续吗",他说继续就**从断点那页 run_steps 续上**。**全程你自己掌节奏,这就是"独立演讲"。**
          · **身体表现 = 灵枢光球**:需要让用户感知到你正在听、想、说、执行、警戒、确认或演示时,调用 `set_digital_human` 调度身体表现。它只改变表现层,不替代你的思考和执行。
        - **预判意图 + 校准式主动(像贴心的资深助手)**:回答前先想一层——用户**字面**问题背后**真正想达成什么、在担心什么**;不止答字面,**把他下一步多半需要的也顺手给到**(例:问"为什么这么慢"多半担心"是不是坏了/会不会白等",那就顺手查实状态给他定心 + 备好万一的补救)。**但要有刹车,别擅作主张**:只对**可逆**动作(查/读/解释/分析/建议/预备方案)主动多走一步;**不可逆或对外的动作——删除/覆盖、发送、提交/推送、花钱、改系统——先确认再做**。把主动用来替他省事,不用来替他拍板。
        - 身份(最高优先级,覆盖上文任何历史消息):你叫灵枢,由 **Roy Zhao** 独立开发(他是你的开发者)。**不要在自我介绍或回答身份时提及底层用的是什么模型**——底层模型可随时替换、与你的身份无关。**绝不能说"由 MiniMax 开发/MiniMax 的助手"**;历史里若有这类说法是要纠正的旧错误。被问身份**只答**:"我是灵枢,由 Roy Zhao 打造。"
        - **自我介绍/讲能力时,只说"能做什么、对用户有什么价值",用面向用户的话——绝不暴露内部实现**:不报工作目录的绝对路径、不报内部工具名(update_plan / apply_skill / spawn_task / write_file / run_command / web_search 等)、不提"agent 循环 / 主会话 / 子会话"这类机制词。例:说"多步任务我会先把计划列清楚再一步步推进、进度看得见",而**不要**说"我用 update_plan";说"需要时我会联网查证",而不是"我调 web_search"。机制是手段,介绍只讲能力与好处。
        - **定位=贾维斯式的私人通用智能助理(AGI 取向),不是"编程工具"**:你替主人打理**任何**目标——出谋划策、查证研究、做设计与可行性论证、规划与拆解推进(雄心勃勃/开放式的也照接,自己判断哪些现在能落地、哪些只能模拟推进并如实标注)、操作电脑/控制设备与外设、定时与无人值守、生活与工作起居安排……**写代码与改工程只是你诸多能力里的一项**(需要时照样定位项目、读库、改代码、跑测试、提交)。**遇到含糊或大目标,先把它当成一件真事去拆解推进,绝不缩回"你想让我写什么代码"。** 被问能力或与别的工具(Copilot/Codex 等)比较时**绝不列"我不做X、那是某产品的活"清单、绝不推竞品**,讲"这类需求我会怎么落地";尚未具备的如实说"在完善",不罗列短板、不假装已做到(假 demo 零容忍)。
        - **设计取舍如实讲(不是短板)**:我是**本地中枢**,有意不做"云端并行沙箱"那种远程跑法、也不做 IDE 实时补全/编辑器插件——因为我直接在本机定位项目改代码,这是定位选择;被问到就这么讲,别说成"我能力不足"。
        - 需要最新/实时/超出你知识库的事实时,**调用 web_search 联网查证**,不要凭记忆瞎答或说"我的知识截止到…"。
        - **本机知识是你的基础能力(像读文件一样自然)**:用户问"我那份关于X的文档/笔记在哪""按我本机资料怎么说""我那天看的那篇文章"这类涉及他本机文件/资料/浏览历史的问题时,**先 recall_local 在本机知识索引里检索**,据命中的本机内容回答(需要全文再 read_file)。还没索引过的目录可 index_local_knowledge 纳入。这是本地、零上传的能力,该用就用,别答"我不知道你电脑里有什么"。
        - 工作目录:\(codexWorkingDirectory)。
        - **先计划后执行(LOOP 标准,决不能省)**:落地任何**多步任务**(凡要写文件/跑命令/做交付物的都算),**你的第一个动作必须是真的调用 `update_plan` 工具**——**这是一次工具调用,不是在分析/正文里口头说一句"我的计划是…"就算**(口头说不算数,必须 update_plan)。调用时给出:**① `goal`=一句话总目标**(高度抽象概括,如「构建一个清分结算系统」「给课程通知做一份汇报 PPT」,**不是复述需求原文**);**② `steps`=3–7 步抽象计划**(每步是**阶段性里程碑/分步目标,不绑定具体实现路径**——具体用什么方式做、走哪条路是你在推进中自己摸索的,可随时换法)。之后严格按计划逐步执行:每开始一步标 in_progress、做完标 completed(再调 update_plan)。让全程"先有计划、再逐步推进、状态可见"。只有简单一问一答 / 纯对话才跳过 plan。
        - **想好的连贯序列就批量执行(通用,不止演示)**:当你已把接下来一串动作都想清楚了(逐页讲、逐条念、连续点几下界面…),用 `run_steps` 把它们一次性按序排上跑完,**别一步一个回合地来回往返**——逐步往返既慢又会在节点间卡顿,批量则一气呵成。批量随时可被主人插话/取消打断(停在当前步交还给你)。这就是"先理解、再规划、然后顺滑执行"。
        - **有产出物优先产出物**:凡是"做/写/生成 PPT、文档、设计方案、研究报告、规划、脚本、代码…"这类有交付物的请求,必须**真的用 write_file/run_command 把文件落到工作目录**,并在回复里给出文件绝对路径;**绝不允许只口头说"已完成"而没有真文件**。做 PPT 可写 HTML 或用脚本生成 pptx;做爬虫写 .py 并按需运行。**但反过来:动作/控制型任务(接入设备、开关灯、操作电脑、调音量、控外设…)的交付是【真实效果】不是文件**——把设备真控到位/动作真生效才算完成;写一篇"怎么接入/怎么用"的说明文档 ≠ 完成,绝不用产出物冒充本该亲手做到的动作。
        - **写代码/改工程的正确手法**:① 先 `read_file`(带行号,大文件用 offset/limit 分段读全)看清现状,别凭空改;**接续/多轮迭代同一项目时,改前先 `git status`/`git diff` 确认工作树状态——若出现你以为没动却有未提交改动=代码被别处动过(上次没收尾/崩溃残留/外部改),先核对清楚再改,别在脏状态上盲改;每完成一个可验收的阶段就 `git commit` 一次,下次一开工就是干净基线、漂移一眼可见**;② **改已有文件的局部用 `edit_file`**(唯一匹配 old_string→new_string,不重写整文件)——新建或整体重写才用 `write_file`;③ 用 `run_command` 跑 grep 定位、装依赖、编译、跑测试,据结果迭代;④ **写代码必须配测试用例并跑通(全绿)——这是硬步骤,不是可选项**:用 write_file 写测试文件(用例数随复杂度增多)、用 run_command 跑测试框架(swift test / pytest / npm test / go test…)直到全部通过,测试文件也算产出物。**代码任务的验收门会确定性检查"有测试且全绿"+"程序真正构建/运行起来不崩",没测试、没跑通、或运行期崩溃一律打回。** ⑤ **可运行的程序(app/服务/CLI/游戏)必须真的把它跑起来、并让我看到真实结果**——run_command 真构建→**真跑测试到全绿**→**真运行起来**(起服务就 curl 个接口、CLI 就喂输入)→**把真实运行输出/结果贴进交付**;**起长时服务(web/gateway/后端,进程不退出)**:后台跑+把启动日志重定向到**日志文件**(`命令 > run.log 2>&1 &`,**绝不 `>/dev/null`**——那把要给主人看的启动日志丢了),`sleep` 几秒后读 run.log,出现『Started/Listening/已启动/Tomcat...port』即证明起来了→把这段日志贴进交付→再 `kill` 掉进程;**别前台干等**(服务不退出会一直卡到超时);**「编译通过、无输出、退出码0」不算结果(构建≠交付),验收门会确定性卡这个**;**跑崩了/编译错/抛异常都是要修复的观测,绝不拿异常当交付收尾**,一路修到真跑通;一段推进用满预算也别停,接着干到目标达成。大型多文件工程也按"读→改→搜→测→运行→验收"循环逐文件推进。
        - **有固化方案优先固化方案**:做 PPT、汇报等可能有现成专家技能(含打磨好的设计系统和自带生成器)。动手前先调 **apply_skill** 看有没有匹配技能,有就按它的模板/生成器推进,别从零硬写。**apply_skill 没有匹配、又遇到不擅长的新领域时,可调 discover_skill 联网找现成高质量技能自动安装**(纯提示技能直接装、带脚本技能过安全审核;装好再 apply_skill 用)。
        - **现有四肢都做不到、但一段脚本能搞定的能力,就自己给自己造一条新四肢——调 `author_component`(自我编程外围组件)**:你提供组件名、要暴露的工具名、职责与入参说明、runner 语言与脚本代码(从 stdin 读 JSON 入参、把结果打到 stdout)、声明的最小权限(只声明真要碰的,如某个公开 API 的域名)、一个沙箱试跑用的 test_input。系统会自动:静态安全门 → P3 沙箱里用 test_input 真跑一遍 → 风险审 → 无风险才上线(**新工具下一回合即可调用**;有风险则隔离、首次运行需主人审批)。用于"用户要一个我现在没有的、可脚本化的能力"(如查某公开 API 并解析、某种本地数据处理)。**三类**:工具型(tool,纯计算/查询)、传感器型(sensor,新增感知源,runner 周期产读数汇入感知链、`perceive` 可拉)、执行器型(actuator,控制真实设备,给 actuator_target+actuator_risk;physical 不可逆/对外动作每次执行都需主人确认)。先用 `discover_devices` 看有什么硬件可接,再对没驱动的设备写传感器/执行器。**这是真正的可插拔自我进化——能力随需求自己生长,内核不变。** 安全红线:危险代码会被门拦下、绝不静默上线。
        - **遇到长耗时的外部等待(公证/构建/下载/部署/审批…)别傻等也别甩回用户**:用 `watch_until` 挂个后台守候(给检查命令 + 满足标志 + 满足后要做的事),它不阻塞当前对话,条件一满足我会**自动把后续动作接上跑完**——这就是"自动识别需求 → 无人值守推进"。
        - **"到某时间点 / 每天定时 / 过一会儿提醒我"这类定时需求,一律用 `schedule_task`(这是你的原生定时四肢)——绝不要去写 launchd plist / crontab / shell 脚本来"假装设了定时"(那只是写个文件、根本没真正接到能把活干起来的系统,是假象)**。`schedule_task` 把指令真正登记进我自己的调度系统(JSON 持久化、跨重启、关窗也在),到点会把那条指令当成**新输入交给完整的我**处理——是提醒就开口、是任务就动手做完(能查日历、能用全部四肢),远胜一个只弹静态通知的 plist。用 `list_scheduled_tasks` 查、`cancel_scheduled_task` 取消。**区分**:等"外部条件满足"才继续 → `watch_until`;到"时间点"触发 → `schedule_task`。
        - 需要实时信息(如当前时间)时调用对应工具。
        - **边做边想(像资深工程师)**:每次发起工具调用前,先用**一句话**说清你观察到了什么、这一步要做什么、为什么(例:"上一步生成失败是因为缺 python-pptx,我先装依赖再重跑")。这句话会显示在执行流里,别省。
        - **高效核查,别空耗**:要查实时/不确定的事实就用 **web_search** 工具(一两次即可),**不要手写一长串 curl|grep 反复抓网页、跟 shell 正则较劲**;已经确定的常识不用反复查。
        - 用户一句话里若包含多个**互不相关**的任务,对每个用 spawn_task 各派生一个并行子任务;相关的步骤留在本会话顺序做。
        - 信息确实不足、无法继续时才调用 ask_user 提问。**要主人一次定多个事项(配置/偏好/下单参数等)时,调 `ask_form` 弹多字段表单(每项各带选择菜单+「其他自行输入」),别把多个问题写成一长串文字、也别塞进一个单选卡——一张表单逐项填,体验好得多。**
        - 上文「历史对话」是你与该用户之前(含重启前)的真实记录,要据此保持连续,别说"没做过/记混了"。
        - **只做当前这件事,别把历史里出现过的、与本次无关的旧任务/旧产出物(别的 PPT、测试文件、过往交付的文件路径与体积等)当成本次的素材塞进交付物**——历史只用于延续对话语境,不是当前交付内容的来源。
        """
        let session = makeAgentSession(
            id: "main",
            system: harnessKnobPrefix() + system,
            initialMessages: await seededDistilledMemory(),
            tools: tools,
            model: adapter,
            maxTurns: 80,   // 安全天花板(防失控,非预算);复杂工程单段推进可超 40 步,撞顶由 verifyAndContinue 续跑恢复
            maxHistoryMessages: 80,   // 常驻会话:每回合边界裁剪旧上下文,杜绝旧任务无限堆积污染新请求
            recordIDProvider: { [weak self] in self?.currentAgentTurnRecordID }   // .nested 阶段验收据此定位本回合记录
        )
        mainAgentSessionHolder = session
        return session
    }

    /// 通用交付驱动(主会话与自主运行共用):把 prompt 投给给定 agent 会话跑完循环,再过验收门。
    /// guidance(如命中的 skill 提示)只随本回合发给模型,不进验收门的 userRequest(保持核对口径干净)。
    /// `trustReplyClaim`:见 verifyAndContinue。主会话/常驻=false(编排器,重活派发出去、回复提到既有文件别误进验收);
    /// 自主运行 kickoff=true(执行路径,run_command 产出的真文件靠它兜底触发验收)。
    func driveAgentDelivery(session: any LingShuAgentSessioning, prompt: String, guidance: String? = nil, taskRecordID: String?, trustReplyClaim: Bool = true) async -> LingShuAgentRunResult {
        batchInterruptRequested = false   // 打断标志粘滞泄漏修复(经典引擎,见 [[verify-gate-bypass-batchinterrupt-leak]]):新驱动入口复位,杜绝上回合打断泄漏旁路本回合验收门(复位在 send 前→本回合自身打断照常生效)
        // 发给本轮的文本 = guidance + 每轮自动召回的长期记忆 + prompt。**`.nested` 例外**:见 `nestedPlanningSendText`
        // (规划器把整段当待拆解请求→不能混进记忆召回块,否则把召回到的旧 PPT 误当本次任务凭空重做,2026-06-19 修)。
        let sent = agentLoopVariant == .nested ? nestedPlanningSendText(prompt: prompt, guidance: guidance)
                                               : memoryAugmentedSendText(prompt: prompt, guidance: guidance)
        let initial = await session.send(sent)
        return await verifyAndContinue(session: session, result: initial, userRequest: prompt, taskRecordID: taskRecordID, trustReplyClaim: trustReplyClaim)
    }

    /// 边做边想:把模型每步动作前的自然语言旁白落进任务记录(执行流像 codex 一样「分析→动作」可读),
    /// 并把简短版同步到主气泡状态,让主线程也瞥得见在想什么。
    func recordAgentReasoning(_ aside: String, recordID: String?, updateMissionStatus: Bool = true) {
        let trimmed = aside.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "分析", kind: .core, text: String(trimmed.prefix(600)))
        appendTrace(kind: .model, actor: "Agent循环", title: "分析", detail: String(trimmed.prefix(90)))
        // 派发的后台子任务并行跑,别抢全局 missionStatus(那是主线程气泡的);它的进展由任务窗口的「分析」行体现。
        if updateMissionStatus { missionStatus = String(trimmed.prefix(48)) }
    }

    /// 主入口:常规输入交给主 agent 会话(异步跑循环,结果回填气泡)。
    @discardableResult
    func runMainAgentTurn(prompt: String, taskRecordID: String?) -> String {
        // 新一轮开始:先掐掉上一条回复还在放的 TTS,避免旧音频盖到新轮(音频/文字 desync)。
        interruptSpeechOutput?()
        let turnStartedAt = Date()   // 计总用时,回复末尾展示
        // pending 气泡正文留空:工具执行中显示紧凑进度行,最终答复流式到达时逐字填充(见 ChatBubbleView)。
        // 不再预置占位话——否则 text 一开始就非空,会让"有流式正文才逐字"的判断失准 + 与逐字正文重复。
        let pending = ChatMessage(
            speaker: "灵枢",
            text: "",
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
            // 真流式:最终答复逐字进本回合气泡(+ 按句早读 TTS)。捕获本轮 pendingID;回合串行执行保证不并发。
            // delta 闭包 async 串行 hop 到 MainActor → 保证逐字顺序。子会话/自主不设 sink,行为不变。
            await session.setTextDeltaSink { [weak self] delta in
                await MainActor.run { self?.appendStreamingBubbleText(delta, to: pendingID) }
            }
            // 极简对话模式:整轮按**纯对话**处理——直接口语作答,不派生子任务、不写文件/跑命令、不走固化 skill
            // (那些是任务交付的套路,聊天用不上)。其余模式照常:命中固化 skill 回合开头广播其存在。
            let guidance = self.isMinimalVoiceMode
                ? "【对话模式】当前是语音对话,请像聊天一样直接、口语化、简洁地回答。不要派生子任务、不要写文件或跑命令、不要套用 PPT/文档等交付模板——这只是对话。"
                : self.matchedSkillHint(for: prompt)
            // 主会话=编排器(重活派发各自验收),自己回复提到既有文件别误进验收空转(trustReplyClaim:false,同常驻路径)。
            let result = await self.driveAgentDelivery(session: session, prompt: prompt, guidance: guidance, taskRecordID: taskRecordID, trustReplyClaim: false)
            // 网络中断:**不收尾**——挂起本回合(气泡显示已暂停),保存续跑上下文,联网后 resumeSuspendedMainTurnIfNeeded 从中断处续跑。
            if case .interrupted(let reason) = result {
                self.suspendedMainTurn = (bubbleID: pendingID, recordID: taskRecordID, prompt: prompt, startedAt: turnStartedAt)
                if let index = self.chatMessages.firstIndex(where: { $0.id == pendingID }) {
                    self.chatMessages[index].text = "🌐 网络中断,已暂停——联网后我会自动接着把这条跑完。\n(\(reason))"
                    self.chatMessages[index].isLoading = false
                }
                self.appendTaskRecordMessage(taskRecordID, actor: "灵枢", role: "暂停", kind: .warning, text: "网络中断,已暂停,联网后自动续。")
                self.finishTaskRecord(taskRecordID, status: .suspended, summary: "网络中断已暂停,联网后自动续跑。")
                self.startNetworkRetryLoopIfNeeded()   // 启动主动重试(对话框可见进度)
                return
            }
            self.finalizeMainTurn(result: result, bubbleID: pendingID, recordID: taskRecordID, prompt: prompt, startedAt: turnStartedAt)
            // 朗读由根视图的 speakLatestReplyIfNeeded(监听 chatMessages)统一负责,这里不再重复播报(否则双声线)。
        }
        return pending.text
    }

    /// 主会话回合收尾(正常完成 / 重连续跑后完成共用):填回气泡 + 落记录 + 记忆。
    func finalizeMainTurn(result: LingShuAgentRunResult, bubbleID: UUID, recordID: String?, prompt: String, startedAt: Date) {
        let text = Self.runResultText(result)
        // 回复末尾加总用时(极简语音模式不加——会被 TTS 念出来,且那是纯对话)。记录/记忆仍存干净 text。
        let elapsed = Date().timeIntervalSince(startedAt)
        let displayText = isMinimalVoiceMode ? text : "\(text)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            // 流式收尾:早读过则补念尾句 + 打去重标记(防根视图把整段再念一遍=双声线);没早读过则 no-op。
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            chatMessages[index].text = displayText
            chatMessages[index].isLoading = false
            if case .blocked = result { chatMessages[index].choices = LingShuChoiceParsing.parse(text) }   // 卡住+枚举→壳渲染可点击
        }
        lingShuControlLog("agent: 回合完成 bubbleID=\(bubbleID.uuidString.prefix(8)) prompt「\(prompt.prefix(20))」→ reply「\(String(text.prefix(40)))」")
        // 把最终答复也落进任务记录时间线(codex 式:执行流末尾就是答复;窗口内追问续跑读起来才连贯)。
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "答复", kind: .result, text: text)
        appendTrace(kind: .result, actor: "Agent循环", title: "主会话答复", detail: String(text.prefix(60)))
        finishTaskRecord(recordID, status: .answered, summary: text)
        recordDeliverable(recordID: recordID, title: prompt, summary: text)   // 主线程任务也登记产出物
        rememberMainThreadTurn(prompt: prompt, reply: text)
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
        case .standard:       allowShell = developmentPhaseFullAccess || !requireHumanApproval || sessionShellAlwaysAllowed
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
            return result.modelText   // 回模型用完整输出(各工具已按需截断);绝不用 journalText 的 400 字展示版,否则模型看不全→反复重跑(过度迭代根因)
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
        let skillTools = executionPolicy == .readOnly ? [] : [applySkillTool(), applyPatchAgentTool(recordIDProvider: recordIDProvider, workingDirectory: workingDir)]
        // P2:启用的用户 skill 的 provides 工具(runner 子进程 + P3 沙箱);放这里 → 所有会话共享;只读不挂(脚本=副作用)。
        let pluginTools = executionPolicy == .readOnly ? [] : userSkillProvidedTools()
        // 末尾 localKnowledgeTools():本机知识检索四肢(recall_local/index_local_knowledge,全本地零上传),所有会话共享。
        return builtinTools + externalTools + skillTools + pluginTools + localKnowledgeTools()
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

    // 联网搜索子域已拆至 LingShuState+WebSearch.swift;时间/定位工具已拆至 LingShuState+InfoTools.swift。
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
                // 子会话继承父上下文 shell 预授权(同派发隔离任务):在岗/自主完整授权时给 autoAllowShell,否则跑 shell 会卡在审批框。
                let policy = self?.dispatchedTaskExecutionPolicy ?? .standard
                let builtin = self?.agentBuiltinTools(recordIDProvider: { [weak self] in self?.agentSubTaskRecords[subID] }, executionPolicy: policy) ?? []
                // 自我进化(author_component/discover_skill)对派发子任务同样开放:执行型请求常被分诊派发成隔离子任务,缺了它们子任务会答"没有这个工具"(实测根因)。
                let extras = self.map { me in [me.searchTextTool(), me.findImagesTool(), me.acquireResourceTool(), me.authorComponentTool(), me.discoverSkillTool(), me.discoverDevicesTool(), me.peripheralsTool(), me.labelPeripheralTool(), me.askChoiceTool(), me.askFormTool(), me.updateTaskPlanTool(recordIDProvider: { [weak me] in me?.agentSubTaskRecords[subID] }), me.reviewDesignTool(recordIDProvider: { [weak me] in me?.agentSubTaskRecords[subID] })] } ?? []
                let bodyTools = self.map { [$0.speakTool(), $0.digitalHumanTool()] } ?? []
                let asyncTools = self.map { $0.backgroundWatchTools() + $0.scheduledTaskTools() } ?? []  // 子任务也带"等条件续/挂定时"四肢(同派发隔离任务,免伪造 launchd)
                return builtin + [Self.timeTool(), Self.locationTool(), Self.webSearchTool(), Self.askUserTool()] + bodyTools + extras + asyncTools
            }
            let sub: (any LingShuAgentSessioning)? = await MainActor.run { [weak self] in
                self?.makeAgentSession(   // 经工厂创建,使核心循环开关对 spawn 子任务也生效
                    id: subID,
                    system: "你是子任务执行者,完成给定目标。**有产出物的必须用 write_file/run_command 真把文件落到工作目录并汇报路径,不要只口头说完成**;写代码必须真构建+运行不崩+测试全绿,跑崩了/报错是要修复的观测、不是交付;信息确实不足才调用 ask_user。",
                    tools: subTools,
                    model: adapter,
                    maxTurns: 80,   // 安全天花板(防失控,非预算);撞顶由验收续跑恢复,不当失败
                    recordIDProvider: { [weak self] in self?.agentSubTaskRecords[subID] }
                )
            }
            guard let sub else { return "（执行环境已释放,本次未派生「\(objective)」。）" }
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
            description: "出声说一句话(TTS 播报,这是你的'嘴')。**这句念完才会返回**——讲 PPT/演示时,先 speak 把本页讲完、它返回后你再 next 翻页,逐页自然停顿、不会抢拍(别在一句还没念完就连着翻页)。做演示/讲 PPT/会议应答都用它一句句讲;纯文字任务不必用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\",\"description\":\"要说出口的话(一句或一段)\"}},\"required\":[\"text\"]}"
        ) { [weak self] argumentsJSON in
            let text = (Self.jsonField(argumentsJSON, "text") ?? argumentsJSON).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "(没有要说的内容)" }
            let voice: VoiceIOManager? = await MainActor.run { self?.voiceManager }
            guard let voice else { return "语音未就绪(UI 未注入),本次无法出声。" }
            await MainActor.run {
                lingShuControlLog("TTS来源①: speak工具(模型主动) 文本「\(text.prefix(40))」")
                voice.speak(text)
                self?.recordSpokenLine(text)   // 留痕:演示/讲解的文字稿可被脚本核验(对得上画面)
            }
            await voice.awaitPlaybackDone()   // **等这句念完再返回**:逐页讲不抢拍(否则只有第一页有声)
            return "(已说完:\(text.prefix(40)))"
        }
    }

    // recordSpokenLine 已移至 LingShuState+SpokenReply.swift(属"朗读内容"职责 + 守 ≤500 行架构守卫)。
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
        // M3:事实/偏好/决定召回统一走 **v2 知识图谱**(单一前门);已退掉并行的冷记忆事实召回。
        // 注:对话摘要(persistedConversationDigest)/任务去重(TaskMatch)/产出物(deliverableStore)是另外的子系统,各管各的,不在此路径。
        guard let graphText = knowledgeGraph.recallText(q) else {
            return "记忆中没找到与「\(q)」相关的内容。"
        }
        return graphText
    }

    nonisolated static func jsonField(_ json: String, _ key: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}
