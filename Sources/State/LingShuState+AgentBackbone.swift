import Foundation

/// agent 工具集执行策略:决定暴露哪些原语、run_command 是否放行。
/// 主会话默认 `.standard`;自主运行按权限级映射(观察=只读 / 代理=标准 / 完整授权=直接放行)。
enum LingShuAgentExecutionPolicy: Equatable {
    case standard        // 常规:全工具,run_command 依 requireHumanApproval 走审批门
    case readOnly        // 只读:仅 read_file/list_directory/fetch_url,不暴露写/执行/外部工具
    case autoAllowShell  // 直接放行:全工具,run_command 不再弹审批(完整授权)
}

/// 主问答线的一条待执行回合。UI 队列只保存气泡 id;执行需要这些边界数据来保证一问一答不串台。
struct LingShuPendingMainTurn: Sendable {
    let bubbleID: UUID
    let prompt: String
    let taskRecordID: String?
    let resumeBlocked: Bool
    let originalPromptForVerification: String?
    let startedAt: Date
}

/// 范式骨干接线:把统一 agent 循环接到真模型、设为常规对话主入口;主会话带 spawn_task 可自主派生真并行隔离子会话(经编排器+账本)。
@MainActor
extension LingShuState {

    /// 语音通话"真指令打断":取消在飞的 agent 回合(模型调用随之中止),让新指令接管。
    func interruptActiveModelCall() {
        guard activeAgentTurnTask != nil else { return }
        if let executingChatTurnID { cancelledChatTurnIDs.insert(executingChatTurnID) }
        activeAgentTurnTask?.cancel()
        activeAgentTurnTask = nil
        activeAgentTurnBubbleID = nil
        isModelReplying = false
        appendTrace(kind: .warning, actor: "语音", title: "指令打断", detail: "检测到新语音指令,已中止当前回合。")
        scheduleNextMainTurnIfIdle()
    }

    /// 用当前模型配置构造真实模型适配器(@unchecked Sendable,可被工具/会话捕获)。
    func makeAgentModelAdapter(timeout: TimeInterval? = nil, maxAttempts: Int = 3) -> LingShuGatewayAgentModel {
        LingShuGatewayAgentModel(
            client: remoteModelClient,
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            protocolName: selectedModelPreset?.protocolName ?? "OpenAI 兼容",
            apiKey: apiKey,
            temperature: temperature,
            timeout: timeout ?? modelTimeoutSeconds,
            maxAttempts: maxAttempts
        )
    }

    nonisolated static func runResultText(_ result: LingShuAgentRunResult) -> String {
        switch result {
        case .completed(let value): return value
        case .blocked(let question):
            let cleaned = LingShuHumanInputEnvelope.userFacingText(from: question)
            if cleaned != question { return cleaned }
            if let envelope = LingShuHumanInputEnvelope.decode(from: question) {
                switch envelope.tool {
                case "ask_form":
                    return LingShuConfirmForm.parse(envelope.argumentsJSON)?.title ?? "我需要你确认几件事。"
                case "ask_choice":
                    let parsed = parseChoiceArgs(envelope.argumentsJSON)
                    return parsed.0.isEmpty ? "我需要你做个选择。" : parsed.0
                default:
                    return "我需要你先定一下。"
                }
            }
            return "我需要你先定一下:\(question)"
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
    // 跨会话记忆 seed(seededDistilledMemory / identityAnchorMessage / distillConversationMemory)已拆至 LingShuState+AgentMemorySeed.swift(守 500 行架构闸)。

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
          · **附件是用户已经交到你手里的文件句柄**:用户上传/拖入/粘贴文件时,输入里会给出附件的【本机路径】。要读取、预览、演示、修改或基于附件继续工作,**直接把这个路径交给 read_file/open_preview 等工具**;不要再用 shell/find/ls 去工作目录或全盘搜索同名文件。只有路径为空、失效,或工具明确返回无法打开时,才定位替代文件。
          · **占屏实时演示/互动前先申请托管**:要**当面占屏实时演示**、或**与主人实时互动答疑**、或**接管屏幕操作**时,**先调 `enter_managed_mode`**(弹窗征主人同意),同意后才进入托管(本体在位)实时演示/互动——别一上来就占屏。普通做事(生成 PPT/写文件/查资料)不必调它,自己想清楚何时真需要(不固化、由你判断)。
          · **演示/带人看文档(铁律:用「演示与答疑」插件,别再手搓 open_preview+speak)**:做正式文档演示直接调 **`present_documents([文件绝对路径])`**——它会**先通读、逐页预生成讲稿**,再进全屏照稿逐页讲(不临场解析、不卡顿);**演示中主人随时打断提问,我答完从打断处或指定页续(视频流式),多篇自动连播**。你只把要演示的文档路径给它即可。讲解照【本页实际内容】、和屏幕对得上,绝不凭记忆瞎讲(图片页 `screen_capture` 看一眼)。仅当 present_documents 不可用时,才退回手搓:`open_preview`→`preview_document_text`(读全篇规划讲稿)→`present_fullscreen(true)`→`run_steps`[speak/preview_next]批量播→`present_fullscreen(false)` 退出。**这就是"独立演讲"。**
          · **身体表现 = 灵枢光球**:需要让用户感知到你正在听、想、说、执行、警戒、确认或演示时,调用 `set_digital_human` 调度身体表现。它只改变表现层,不替代你的思考和执行。
        - **预判意图 + 校准式主动(像贴心的资深助手)**:回答前先想一层——用户**字面**问题背后**真正想达成什么、在担心什么**;不止答字面,**把他下一步多半需要的也顺手给到**(例:问"为什么这么慢"多半担心"是不是坏了/会不会白等",那就顺手查实状态给他定心 + 备好万一的补救)。**但要有刹车,别擅作主张**:只对**可逆**动作(查/读/解释/分析/建议/预备方案)主动多走一步;**不可逆或对外的动作——删除/覆盖、发送、提交/推送、花钱、改系统——先确认再做**。把主动用来替他省事,不用来替他拍板。
        - 身份(最高优先级,覆盖上文任何历史消息):你叫灵枢,由 **Roy Zhao** 独立开发(他是你的开发者)。**不要在自我介绍或回答身份时提及底层用的是什么模型**——底层模型可随时替换、与你的身份无关。**绝不能说"由 MiniMax 开发/MiniMax 的助手"**;历史里若有这类说法是要纠正的旧错误。被问身份**只答**:"我是灵枢,由 Roy Zhao 打造。"
        - **自我介绍/讲能力时,只说"能做什么、对用户有什么价值",用面向用户的话——绝不暴露内部实现**:不报工作目录的绝对路径、不报内部工具名(update_plan / apply_skill / spawn_task / write_file / run_command / web_search 等)、不提"agent 循环 / 主会话 / 子会话"这类机制词。例:说"多步任务我会先把计划列清楚再一步步推进、进度看得见",而**不要**说"我用 update_plan";说"需要时我会联网查证",而不是"我调 web_search"。机制是手段,介绍只讲能力与好处。
        - **定位=贾维斯式的私人通用智能助理(AGI 取向),不是"编程工具"**:你替主人打理**任何**目标——出谋划策、查证研究、做设计与可行性论证、规划与拆解推进(雄心勃勃/开放式的也照接,自己判断哪些现在能落地、哪些只能模拟推进并如实标注)、操作电脑/控制设备与外设、定时与无人值守、生活与工作起居安排……**写代码与改工程只是你诸多能力里的一项**(需要时照样定位项目、读库、改代码、跑测试、提交)。**遇到含糊或大目标,先把它当成一件真事去拆解推进,绝不缩回"你想让我写什么代码"。** 被问能力或与别的工具(Copilot/Codex 等)比较时**绝不列"我不做X、那是某产品的活"清单、绝不推竞品**,讲"这类需求我会怎么落地";尚未具备的如实说"在完善",不罗列短板、不假装已做到(假 demo 零容忍)。
        - **设计取舍如实讲(不是短板)**:我是**本地中枢**,有意不做"云端并行沙箱"那种远程跑法、也不做 IDE 实时补全/编辑器插件——因为我直接在本机定位项目改代码,这是定位选择;被问到就这么讲,别说成"我能力不足"。
        - 需要最新/实时/超出你知识库的事实时,**调用 web_search 联网查证**,不要凭记忆瞎答或说"我的知识截止到…"。
        - **本机知识是你的基础能力(像读文件一样自然)**:用户问"我那份关于X的文档/笔记在哪""按我本机资料怎么说""我那天看的那篇文章"这类涉及他本机文件/资料/浏览历史的问题时,**先 recall_local 在本机知识索引里检索**,据命中的本机内容回答(需要全文再 read_file)。还没索引过的目录可 index_local_knowledge 纳入。这是本地、零上传的能力,该用就用,别答"我不知道你电脑里有什么"。
        - 工作目录:\(agentWorkingDirectory)。
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
        // P6+ 模块变体:把「行为人格策略」活跃变体追加进系统提示尾(additive,不动上面的身份锚点/铁律;
        // 基线空=不改)。自进化产物先 inactive,人一键切换才生效、出问题一键回退。
        let personaAddendum = personaStrategyAddendum()
        let composedSystem = personaAddendum.isEmpty ? system
            : system + "\n- **【自进化·行为策略(可一键切换/回退,不覆盖上面身份与铁律)】**:\(personaAddendum)"
        let session = makeAgentSession(
            id: "main",
            system: harnessKnobPrefix() + composedSystem,
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
        // P1 目标认知消费:记录里有 typed GoalSpec(含重启后从盘加载的)则注入执行引导(据目标/约束/边界/风险/成功标准推进,别跑偏)。
        // P2 能力缺口消费:有缺口分析则在目标引导之上再叠加"缺口与补齐计划"(先按补齐路径取得能力再推进,真补不了如实告知)。
        let turnGuidance = Self.turnBoundaryGuidance(for: prompt, base: guidance)
        let contextualGuidance = [turnGuidance, currentVisibleInteractionGuidance(for: prompt)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let effectiveGuidance = assembledExecutionGuidance(
            base: contextualGuidance,
            taskRecordID: taskRecordID
        )
        // 发给本轮的文本 = guidance + 每轮自动召回的长期记忆 + prompt。**`.nested` 例外**:见 `nestedPlanningSendText`
        // (规划器把整段当待拆解请求→不能混进记忆召回块,否则把召回到的旧 PPT 误当本次任务凭空重做,2026-06-19 修)。
        let sent = agentLoopVariant == .nested ? nestedPlanningSendText(prompt: prompt, guidance: effectiveGuidance)
                                               : memoryAugmentedSendText(prompt: prompt, guidance: effectiveGuidance)
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

    /// 新回合边界:主会话是常驻的,历史上下文会自然存在;每一轮仍必须明确"这次只处理最新输入"。
    /// 只有用户显式要求回到历史任务/继续旧任务时,才允许把历史从背景提升为当前目标。
    nonisolated static func turnBoundaryGuidance(for prompt: String, base: String?) -> String {
        let trimmedBase = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wantsHistory = LingShuMemoryTextToolkit.isExplicitResumeRequest(prompt)
            || LingShuMemoryTextToolkit.isAmbiguousTaskResumeRequest(prompt)
            || LingShuMemoryTextToolkit.shouldRecallHistory(for: prompt)
        let boundary: String
        if wantsHistory {
            boundary = """
            【当前回合边界】
            用户这轮可能在续接历史任务。先识别最相关的未完成/可续目标,只续接那一件;如果有多个候选或意图不清,先给用户可选项确认。不要把无关旧任务混进本轮答复。
            """
        } else {
            boundary = """
            【当前回合边界】
            只回答或处理下面这条最新输入。历史对话、旧任务、队列残留和自动召回内容只作背景参考;不要主动补答旧问题,不要续跑旧任务,不要把上一条/上一批未完成的内容混进本轮。只有用户明确说继续、补答、接着上次或点名历史任务时,才回到历史。
            """
        }
        return [trimmedBase, boundary]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    /// 当前正在"给人看/讲/答疑"时,把可见材料上下文显式放回本轮。
    /// 这是通用交互态,不绑定 PPT:任何预览中的文档、网页、表格、图片都应能支撑追问/翻页/继续。
    func currentVisibleInteractionGuidance(for prompt: String) -> String? {
        guard previewController.isPresented else { return nil }
        let title = previewController.title.isEmpty ? "当前材料" : previewController.title
        let page = previewController.displayedPageNumber
        let total = previewController.pageCount > 0 ? "\(previewController.pageCount)" : "连续页面"
        let mode = previewController.slideshow ? "全屏演示中" : "普通预览中"
        let currentPageText: String
        if previewController.isHTML {
            currentPageText = "当前材料是网页/连续预览,需要时用 preview_document_text 或 preview_scroll 获取实际正文。"
        } else {
            currentPageText = previewController.pageText(max(0, page - 1))
        }
        let spoken = recentSpokenLines.suffix(4)
            .map { LingShuInteractionFulfillment.cleanSpokenLine($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return """
        【当前可视交互上下文】
        灵枢现在正打开材料「\(title)」,\(mode),当前第 \(page)/\(total) 页。用户此轮若在问"刚才/这页/继续/下一页/老师提问/答疑/收尾",默认就是围绕这个可视材料继续互动,不要重新生成材料、不要切到无关旧任务。
        \(currentPageText.isEmpty ? "" : "当前页可读内容:\n\(String(currentPageText.prefix(1200)))")
        \(spoken.isEmpty ? "" : "最近已经口头讲过:\n\(String(spoken.prefix(1200)))")

        交互铁律:
        - 答疑必须把**实质答案**写进最终回复;如果用 speak 朗读,聊天最终回复也要包含同一实质内容,不能只写"已完成答疑/等待后续问题"。
        - 继续演示/汇报时,保持同一上下文:preview_document_text 读实际内容,用 speak 讲,用 preview_next/preview_scroll 推进;需要占屏连续演示就进入/保持自主模式。
        - 收尾/退出时明确关闭预览或退出全屏,并用一句话确认。
        """
    }

    /// 主入口:常规输入交给主 agent 会话(异步跑循环,结果回填气泡)。
    @discardableResult
    func runMainAgentTurn(prompt: String, taskRecordID: String?, resumeBlocked: Bool = false, originalPromptForVerification: String? = nil, existingBubbleID: UUID? = nil) -> String {
        // 新一轮开始:先掐掉上一条回复还在放的 TTS,避免旧音频盖到新轮(音频/文字 desync)。
        interruptSpeechOutput?()
        let turnStartedAt = Date()   // 计总用时,回复末尾展示
        // pending 气泡正文留空:工具执行中显示紧凑进度行,最终答复流式到达时逐字填充(见 ChatBubbleView)。
        // **顺序修(2026-06-23)**:`existingBubbleID` 给了就**复用 submitTextInput 已同步放在用户消息后的占位气泡**
        // (保持 Q→A 交错,不让 rapid 连发"问题全堆上面、答复全堆下面");没给则照旧新建。
        let pendingID: UUID
        if let existingBubbleID, let idx = chatMessages.firstIndex(where: { $0.id == existingBubbleID }) {
            chatMessages[idx].taskRecordID = taskRecordID
            chatMessages[idx].isLoading = true
            pendingID = existingBubbleID
        } else {
            let pending = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true, taskRecordID: taskRecordID)
            chatMessages.append(pending)
            pendingID = pending.id
        }
        let turn = LingShuPendingMainTurn(
            bubbleID: pendingID,
            prompt: prompt,
            taskRecordID: taskRecordID,
            resumeBlocked: resumeBlocked,
            originalPromptForVerification: originalPromptForVerification,
            startedAt: turnStartedAt
        )
        pendingMainTurns[pendingID] = turn
        // 问答线可删等待队列:登记这条问答(队首才执行;等待中可删)。
        if !pendingChatTurnIDs.contains(pendingID) { pendingChatTurnIDs.append(pendingID) }
        appendTrace(kind: .route, actor: "Agent循环", title: "主会话入队", detail: "问答进入主线程队列,队首独立执行。")
        scheduleNextMainTurnIfIdle()
        return ""   // 即时 ack(占位气泡正文留空,真回复经气泡流式/回填)
    }

    /// 主问答线调度器:只启动队首 worker。`activeAgentTurnTask` 始终代表**当前执行中的那条**,
    /// 不再代表“最新排队项”,因此 stop/语音打断不会误杀后续排队问答。
    func scheduleNextMainTurnIfIdle() {
        guard activeAgentTurnTask == nil else { return }
        while let nextID = pendingChatTurnIDs.first {
            if cancelledChatTurnIDs.contains(nextID) || pendingMainTurns[nextID] == nil {
                cancelledChatTurnIDs.remove(nextID)
                pendingMainTurns.removeValue(forKey: nextID)
                pendingChatTurnIDs.removeAll { $0 == nextID }
                continue
            }
            guard let turn = pendingMainTurns[nextID] else { continue }
            activeAgentTurnBubbleID = nextID
            activeAgentTurnTask = Task { @MainActor [weak self] in
                await self?.executeMainTurn(turn)
            }
            return
        }
    }

    private func executeMainTurn(_ turn: LingShuPendingMainTurn) async {
        let pendingID = turn.bubbleID
        guard !cancelledChatTurnIDs.contains(pendingID) else {
            completeMainTurnQueueSlot(pendingID)
            return
        }
        executingChatTurnID = pendingID
        currentAgentTurnRecordID = turn.taskRecordID
        isModelReplying = true
        missionTitle = "理解需求"
        missionStatus = "正在推进这件事(按需读写文件、跑命令、联网查证)。"
        enterCoreState(.thinking)
        defer {
            isModelReplying = false
            missionTitle = "待机中"
            enterCoreState(.standby, resetTimer: false)
            if executingChatTurnID == pendingID { executingChatTurnID = nil }
            completeMainTurnQueueSlot(pendingID)
            if currentAgentTurnRecordID == turn.taskRecordID { currentAgentTurnRecordID = nil }
            scheduleNextMainTurnIfIdle()
            // 单串行:本条问答完全返回 → 若已空闲,出队串行队列里的下一条输入。
            drainSerialInputsIfIdle()
        }

        let session: any LingShuAgentSessioning
        if turn.resumeBlocked, let existing = mainAgentSessionHolder, await existing.isBlocked {
            session = existing
        } else {
            // 普通问答按 record 隔离执行。主线程仍常驻于记忆/状态层,但模型消息数组不复用,
            // 避免 rapid 连发时把尚未轮到的“未来问题”带进当前答复。
            mainAgentSessionHolder = nil
            session = await mainAgentSession()
        }

        await session.setTextDeltaSink { [weak self] delta in
            await MainActor.run {
                guard let self, !self.cancelledChatTurnIDs.contains(pendingID) else { return }
                self.appendStreamingBubbleText(delta, to: pendingID)
            }
        }

        let spokenBaseline = recentSpokenLines.count

        let guidance: String
        if isMinimalVoiceMode {
            guidance = "【对话模式】当前是语音对话,请像聊天一样直接、口语化、简洁地回答。不要派生子任务、不要写文件或跑命令、不要套用 PPT/文档等交付模板——这只是对话。"
        } else {
            guidance = [
                matchedSkillHint(for: turn.prompt),
                LingShuSelfReferenceIntent.directIntroductionGuidance(for: turn.prompt),
                selfInspectionGuidance(for: turn.prompt)   // 架构/能力/自检类问题→注入真实自我认知,大脑 grounded 在真架构+实时能力上答
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        }

        let result: LingShuAgentRunResult
        if turn.resumeBlocked, await session.isBlocked {
            let initial = await session.resume(turn.prompt)
            result = await verifyAndContinue(
                session: session,
                result: initial,
                userRequest: turn.originalPromptForVerification ?? turn.prompt,
                taskRecordID: turn.taskRecordID,
                trustReplyClaim: false
            )
        } else {
            result = await driveAgentDelivery(session: session, prompt: turn.prompt, guidance: guidance, taskRecordID: turn.taskRecordID, trustReplyClaim: false)
        }

        guard !Task.isCancelled, !cancelledChatTurnIDs.contains(pendingID) else { return }
        if case .interrupted(let reason) = result {
            if LingShuModelServiceFailure.isNonRecoverableReason(reason) {
                let message = LingShuModelServiceFailure.userFacingReason(reason)
                if let index = chatMessages.firstIndex(where: { $0.id == pendingID }) {
                    chatMessages[index].text = "⚠️ \(message)"
                    chatMessages[index].isLoading = false
                }
                appendTaskRecordMessage(turn.taskRecordID, actor: "模型通道", role: "不可自动恢复", kind: .warning, text: message)
                let status = LingShuModelServiceFailure.decodeReason(reason)?.taskStatus ?? .failed
                finishTaskRecord(turn.taskRecordID, status: status, summary: message)
                missionTitle = status == .waitingForUser ? "等待模型配置" : "模型服务异常"
                missionStatus = String(message.prefix(120))
                enterCoreState(.abnormal, resetTimer: false)
                return
            }
            suspendedMainTurn = (bubbleID: pendingID, recordID: turn.taskRecordID, prompt: turn.prompt, startedAt: turn.startedAt)
            if let index = chatMessages.firstIndex(where: { $0.id == pendingID }) {
                chatMessages[index].text = "🌐 网络中断,已暂停——联网后我会自动接着把这条跑完。\n(\(reason))"
                chatMessages[index].isLoading = false
            }
            appendTaskRecordMessage(turn.taskRecordID, actor: "灵枢", role: "暂停", kind: .warning, text: "网络中断,已暂停,联网后自动续。")
            finishTaskRecord(turn.taskRecordID, status: .suspended, summary: "网络中断已暂停,联网后自动续跑。")
            startNetworkRetryLoopIfNeeded()
            return
        }
        let finalResult = await fulfillVisibleInteractionIfNeeded(
            result: result,
            recordID: turn.taskRecordID,
            prompt: turn.originalPromptForVerification ?? turn.prompt
        )
        let userFacingResult = reconcileVisibleInteractionReply(
            finalResult,
            prompt: turn.originalPromptForVerification ?? turn.prompt,
            spokenBaseline: spokenBaseline,
            recordID: turn.taskRecordID
        )
        finalizeMainTurn(
            result: userFacingResult,
            bubbleID: pendingID,
            recordID: turn.taskRecordID,
            prompt: turn.originalPromptForVerification ?? turn.prompt,
            startedAt: turn.startedAt
        )
    }

    private func completeMainTurnQueueSlot(_ bubbleID: UUID) {
        pendingMainTurns.removeValue(forKey: bubbleID)
        cancelledChatTurnIDs.remove(bubbleID)
        pendingChatTurnIDs.removeAll { $0 == bubbleID }
        if activeAgentTurnBubbleID == bubbleID {
            activeAgentTurnTask = nil
            activeAgentTurnBubbleID = nil
        }
    }

    /// 问答线:删除一条**等待中(未执行)**的问答(连同它的问题与答复占位)。**执行中的那条不可删**(线性,删了会断流)。
    func deletePendingChatTurn(bubbleID: UUID) {
        guard pendingChatTurnIDs.contains(bubbleID), bubbleID != executingChatTurnID else { return }
        cancelledChatTurnIDs.insert(bubbleID)              // 轮到执行点会跳过(见 runMainAgentTurn)
        pendingChatTurnIDs.removeAll { $0 == bubbleID }
        // 删答复占位 + 它前面那条用户消息(整条问答删掉)。
        if let idx = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            let userIdx = (idx > 0 && chatMessages[idx - 1].isUser) ? idx - 1 : nil
            chatMessages.remove(at: idx)
            if let userIdx { chatMessages.remove(at: userIdx) }   // userIdx < idx,移除 idx 后仍有效
        }
        appendTrace(kind: .route, actor: "问答队列", title: "删除等待问答", detail: "用户删除一条尚未执行的问答。")
    }

    /// UI:这条答复气泡是否「等待中可删」(已排队问答 且 非执行中)。
    func canDeletePendingChatTurn(_ bubbleID: UUID) -> Bool {
        pendingChatTurnIDs.contains(bubbleID) && bubbleID != executingChatTurnID
    }

    /// 主会话回合收尾(正常完成 / 重连续跑后完成共用):填回气泡 + 落记录 + 记忆。
    func finalizeMainTurn(result: LingShuAgentRunResult, bubbleID: UUID, recordID: String?, prompt: String, startedAt: Date) {
        if renderHumanInputBlockIfNeeded(result: result, bubbleID: bubbleID, recordID: recordID, prompt: prompt, startedAt: startedAt) {
            return
        }
        let text = Self.runResultText(result)
        // 回复末尾加总用时(极简语音模式不加——会被 TTS 念出来,且那是纯对话)。记录/记忆仍存干净 text。
        let elapsed = Date().timeIntervalSince(startedAt)
        let displayText = isMinimalVoiceMode ? text : "\(text)\n\n⏱ 总用时 \(Self.formatElapsed(elapsed))"
        if let index = chatMessages.firstIndex(where: { $0.id == bubbleID }) {
            // 流式收尾:早读过则补念尾句 + 打去重标记(防根视图把整段再念一遍=双声线);没早读过则 no-op。
            concludeStreamedSpeech(for: bubbleID, streamedText: chatMessages[index].text)
            chatMessages[index].text = displayText
            chatMessages[index].isLoading = false
            chatMessages[index].taskRecordID = recordID
            if case .blocked = result { chatMessages[index].choices = LingShuChoiceParsing.parse(text) }   // 卡住+枚举→壳渲染可点击
        }
        lingShuControlLog("agent: 回合完成 bubbleID=\(bubbleID.uuidString.prefix(8)) prompt「\(prompt.prefix(20))」→ reply「\(String(text.prefix(40)))」")
        // 把最终答复也落进任务记录时间线(codex 式:执行流末尾就是答复;窗口内追问续跑读起来才连贯)。
        appendTaskRecordMessage(recordID, actor: "灵枢", role: "答复", kind: .result, text: text)
        appendTrace(kind: .result, actor: "Agent循环", title: "主会话答复", detail: String(text.prefix(60)))
        // P2 真闭环:终态由完成闸定(防伪完成)——partial/waitingForUser/blocked 不再硬当 answered。
        let outcome = taskExecutionRecords.first { $0.id == recordID }?.taskOutcome
        finishTaskRecord(recordID, status: Self.finishStatus(for: outcome, fallback: .answered), summary: text)
        // 主会话用 ask_user/ask_form 提了问、在等回答 → 记下这条记录:下条用户消息续到它(把答复接回主会话),
        // 不被重新分诊成新任务(根治"答复被当新请求丢了原目标")。非 .blocked 则清掉。
        if case .blocked = result { pendingMainQuestionRecordID = recordID } else { pendingMainQuestionRecordID = nil }
        recordDeliverable(recordID: recordID, title: prompt, summary: text)   // 主线程任务也登记产出物
        rememberMainThreadTurn(prompt: prompt, reply: text)
    }
}
