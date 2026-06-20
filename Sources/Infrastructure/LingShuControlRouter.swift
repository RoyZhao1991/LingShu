import Foundation

/// MCP / JSON-RPC 路由：把外部调用映射到灵枢 @MainActor 中枢的内部动作。
///
/// 工具命名空间随 M2 能力链逐块扩充:
/// - 第 1 块(本块):`lingshu_status` / `lingshu_send_prompt` / `lingshu_get_chat` / `lingshu_get_trace`
/// - 第 2 块:`meeting_start_capture` / `meeting_stop_capture`(系统音频采集 → ASR)
/// - 第 3 块:`meeting_get_transcript` / `meeting_generate_minutes`
/// - 第 4 块:`tts_speak`(写入虚拟麦克风)
@MainActor
final class LingShuControlRouter {
    private let state: LingShuState
    static let serverName = "lingshu-control"
    static let serverVersion = "0.1.0"
    static let protocolVersion = "2024-11-05"

    /// 演示用编排器实例(跨 MCP 调用持久,展示真并行/账本/续接)。

    init(state: LingShuState) {
        self.state = state
    }

    /// 处理一条 JSON-RPC 请求体,返回 JSON-RPC 响应体(若为通知则返回空 ack)。
    func handle(requestBody: Data) async -> Data {
        guard
            let object = try? JSONSerialization.jsonObject(with: requestBody),
            let request = object as? [String: Any],
            let method = request["method"] as? String
        else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "解析失败：非法 JSON-RPC"]])
        }

        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion]
            ])
        case "notifications/initialized":
            // 通知无需响应；HTTP 一问一答下回个空体即可。
            return encode([:])
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.toolManifest])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await callTool(name: name, arguments: arguments)
            return reply(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": isError
            ])
        default:
            return reply(id: id, error: ["code": -32601, "message": "未知方法：\(method)"])
        }
    }

    // MARK: - 工具清单

    private static let toolManifest: [[String: Any]] = [
        [
            "name": "lingshu_status",
            "description": "读取灵枢当前核心状态、任务标题/状态、独立运行阶段与会话计数。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "lingshu_send_prompt",
            "description": "向灵枢提交一条文本指令(等价用户输入),返回即时路由/直答结果;模型完整回复会异步进入对话,可用 lingshu_get_chat 轮询。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "要提交的指令文本"],
                    "source": ["type": "string", "description": "输入来源:typed(默认)或 voice"]
                ],
                "required": ["text"]
            ]
        ],
        [
            "name": "lingshu_voice_text",
            "description": "**模拟一句语音指令转写收口后的完整下游处理**(post-STT 入口):无法直接灌音频时,从『音频转文字之后』这一点注入——会先掐掉正在播的 TTS(等价 barge-in 打断),再把这句当语音输入交给大脑(在岗/演示中=自动当『中途插话』注入正在跑的会话/批量,先答再问是否续)。用于完整测试『演示中打断、让它翻到第N页/换内容』这类语音交互。args: text。",
            "inputSchema": [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "已转写成文字的那句语音指令"]],
                "required": ["text"]
            ]
        ],
        [
            "name": "lingshu_get_chat",
            "description": "读取最近若干条对话消息(含说话人、是否用户、是否加载中)。",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "description": "返回条数,默认 20"]]
            ]
        ],
        [
            "name": "lingshu_interject",
            "description": "流程纠正/干预:看到 agent 跑偏时,把纠正注入正在跑的会话,回合边界即采纳改方向(不打断在飞工具)。args: text、recordId(可选,指定某条派发隔离任务的记录 id;不给则注入主会话当前回合)。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "纠正指令"],
                    "recordId": ["type": "string", "description": "(可选)派发隔离任务的记录 id,纠正注入那条隔离会话"]
                ],
                "required": ["text"]
            ]
        ],
        [
            "name": "lingshu_stop",
            "description": "停止当前在飞回合(等价任务窗口停止按钮)。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "lingshu_autonomous",
            "description": "驱动「自主模式/常驻灵枢」(等价独立运行面板按钮):go_live=让灵枢上岗成为常驻灵枢(完全接管)、stop=停止并夺回控制、pause/resume=暂停/继续、arm/disarm=武装/解除自主反应(环境事件唤醒)。状态见 lingshu_status 的 standingPersonOnDuty/autoReactArmed/perceptionDigest。args: action。",
            "inputSchema": [
                "type": "object",
                "properties": ["action": ["type": "string", "description": "go_live | stop | pause | resume | arm | disarm"]],
                "required": ["action"]
            ]
        ],
        [
            "name": "lingshu_task_records",
            "description": "列任务执行记录(热+冷):id/标题/状态/消息数/产出物数/反馈。供挑选后 inspect 或操作。args: limit。",
            "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "返回条数,默认 15"]]]
        ],
        [
            "name": "lingshu_task_detail",
            "description": "取一条任务的 codex 式执行时间线:每条消息含结构化 detail(toolCall/toolResult/fileEdit+diff)+ 产出物 + 反馈。免点开窗口即可核验卡片内容。args: recordId。",
            "inputSchema": [
                "type": "object",
                "properties": ["recordId": ["type": "string", "description": "任务记录 id(来自 lingshu_task_records)"]],
                "required": ["recordId"]
            ]
        ],
        [
            "name": "lingshu_task_followup",
            "description": "对某条任务窗口内追问续跑(同一记录继续,等价底栏发送)。args: recordId, text。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordId": ["type": "string", "description": "任务记录 id"],
                    "text": ["type": "string", "description": "追问内容"]
                ],
                "required": ["recordId", "text"]
            ]
        ],
        [
            "name": "lingshu_task_feedback",
            "description": "给任务设反馈(等价 👍👎;👎 的输出不进 dreaming 固化样本)。args: recordId, value(up/down/clear)。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordId": ["type": "string", "description": "任务记录 id"],
                    "value": ["type": "string", "description": "up / down / clear"]
                ],
                "required": ["recordId", "value"]
            ]
        ],
        [
            "name": "lingshu_undo_edit",
            "description": "撤销一次文件改动(等价 diff 卡的撤销;新增删文件、修改还原改前内容)。args: recordId, messageId(来自 lingshu_task_detail 的 fileEdit 消息)。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "recordId": ["type": "string", "description": "任务记录 id"],
                    "messageId": ["type": "string", "description": "fileEdit 消息 id"]
                ],
                "required": ["recordId", "messageId"]
            ]
        ],
        [
            "name": "lingshu_attach",
            "description": "按文件路径加附件(等价 📎),走与主输入框同一 ingest 管线;随后 lingshu_send_prompt / lingshu_task_followup 会带上附件正文。args: path。",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "本机文件绝对路径"]],
                "required": ["path"]
            ]
        ],
        [
            "name": "lingshu_clear_attachments",
            "description": "清空当前待发送附件缓冲。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "lingshu_clear_context",
            "description": "清空主对话上下文(开启新会话):停掉在飞回合、丢弃常驻会话、聊天与执行轨迹回到初始态。不动任务线程/执行记录,长期记忆保留。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "lingshu_acquire_resource",
            "description": "资源自获取:先查本地资源库,没有就联网下载(模板/图标/字体/参考)入库复用。args: kind(pptx-template/icon-set/font/reference)、query。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "description": "pptx-template / icon-set / font / reference"],
                    "query": ["type": "string", "description": "主题/品类关键词"]
                ],
                "required": ["kind", "query"]
            ]
        ],
        [
            "name": "lingshu_set_credential",
            "description": "把凭据(如数据网关 VL/感知 token)写入灵枢配置数据库(加密落盘,跨重启持久)。args: provider(如 datanet-gateway)、token。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "provider": ["type": "string", "description": "provider id,如 datanet-gateway"],
                    "token": ["type": "string", "description": "凭据 token"]
                ],
                "required": ["provider", "token"]
            ]
        ],
        [
            "name": "lingshu_set_model",
            "description": "切换灵枢的大脑(模型供应商/模型),选择持久化到配置(跨重启保留)。args: provider(供应商名,如 DeepSeek)、model(可选,如 deepseek-chat)。**不返显 api key**(只返回是否已配置 key)。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "provider": ["type": "string", "description": "供应商名,如 DeepSeek / MiniMax 官方"],
                    "model": ["type": "string", "description": "模型名(可选),如 deepseek-chat / deepseek-reasoner"]
                ],
                "required": ["provider"]
            ]
        ],
        [
            "name": "lingshu_main_session",
            "description": "读常驻主会话上下文尾部(role/内容片段/工具调用),用于核验子任务简报、纠正是否注入了主线程上下文。args: limit。",
            "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "返回条数,默认 12"]]]
        ],
        [
            "name": "lingshu_set_loop_variant",
            "description": "切换核心 agent 循环引擎(新旧热切换,调试用):classic=经典连续循环 / nested=嵌套分阶段验收循环(大LOOP含多阶段,任务阶段验交付物、互动阶段不验、阶段间断点续)。持久化跨重启,下回合生效。一键切回 classic 同此。状态见 lingshu_status 的 loopVariant。args: variant(classic|nested)。",
            "inputSchema": [
                "type": "object",
                "properties": ["variant": ["type": "string", "description": "classic 或 nested"]],
                "required": ["variant"]
            ]
        ],
        [
            "name": "lingshu_get_trace",
            "description": "读取最近若干条执行轨迹事件(路由/模型调用/工具输出等),用于核验内部流转。",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "description": "返回条数,默认 30"]]
            ]
        ],
        [
            "name": "meeting_start_capture",
            "description": "启动系统音频采集(听会议)。用 ScreenCaptureKit 数字抓取系统输出音频,不经麦克风、不录自己。首次会触发屏幕录制授权。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "meeting_stop_capture",
            "description": "停止系统音频采集。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "meeting_capture_status",
            "description": "读取系统音频采集状态:是否在采、时长、帧数、当前/峰值音量、采样率、最近错误。音量>0 即证明真的采到声音。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "meeting_get_transcript",
            "description": "读取会议语音识别(ASR)的当前转写文本、已喂帧数与最近错误。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "meeting_converse_start",
            "description": "开始会议端到端对话:听会议(系统音频→ASR)→ 灵枢自动应答(经 agent 全能力,可对话/可演示 PPT)→ TTS 播出(配虚拟麦回到会议)。需屏幕录制权限。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "meeting_converse_stop",
            "description": "结束会议端到端对话(停止听+应答)。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "agent_demo_start",
            "description": "演示 agent 编排骨干:并发派生两条隔离子会话(A 直接完成、B 中途卡住提问),返回统一账本 + 主动推送 + 在跑/排队数。展示真并行/隔离/卡住汇报。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "agent_resume",
            "description": "凭账本把答案续接给某条卡住的子会话,让它续跑到完成。args: id(子会话id)、answer(补充内容)。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "卡住子会话的 id"],
                    "answer": ["type": "string", "description": "补充/答案文本"]
                ],
                "required": ["id", "answer"]
            ]
        ],
        [
            "name": "agent_ledger",
            "description": "读取 agent 编排器的统一账本(各子会话 目标/状态/摘要/卡在什么)、主动推送、在跑与排队数。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "agent_run",
            "description": "用【真实模型】跑一次 agent 编排循环(模型↔工具多轮)。带一个安全工具 get_current_time;模型可自行决定是否调用。返回最终答复 + 实际调用过的工具 + 轮次,用于验证真模型驱动循环。args: prompt。",
            "inputSchema": [
                "type": "object",
                "properties": ["prompt": ["type": "string", "description": "要交给真模型 agent 的指令"]],
                "required": ["prompt"]
            ]
        ]
    ]

    // MARK: - 工具实现

    private func callTool(name: String, arguments: [String: Any]) async -> (text: String, isError: Bool) {
        switch name {
        case "lingshu_status":
            return (jsonText(statusPayload()), false)
        case "lingshu_send_prompt":
            guard let text = (arguments["text"] as? String), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("缺少参数 text", true)
            }
            let source: LingShuDialogueInputSource = (arguments["source"] as? String) == "voice" ? .voice : .typed
            // 带上待发附件(与 UI sendPrompt 同口径)——修"MCP 发送时附件没一并带出"的 bug。
            let reply = state.submitTextWithAttachments(text, source: source)
            return (jsonText(["submitted": text, "immediateReply": reply]), false)
        case "lingshu_voice_text":
            // post-STT 入口:模拟"一句语音指令已转写收口"的完整下游——先掐 TTS(等价 barge-in),再走 submitVoiceTranscript
            // (=submitTextInput(.voice);在岗/演示中会自动当『中途插话』注入正在跑的会话/批量)。供无音频时完整测语音打断/翻页。
            guard let text = (arguments["text"] as? String), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("缺少参数 text", true)
            }
            let wasSpeaking = state.voiceManager?.isSpeakingOrQueued ?? false
            let wasActive = state.hasActiveModelCall
            if wasSpeaking || wasActive { state.interruptSpeechOutput?() }   // 掐正在播的 TTS,与真实 barge-in 同
            let vReply = state.submitVoiceTranscript(text)
            return (jsonText(["voiceSubmitted": text, "bargedInTTS": wasSpeaking, "wasActive": wasActive, "immediateReply": vReply]), false)
        case "lingshu_interject":
            // 流程纠正(干预):把纠正注入正在跑的会话,看到 agent 跑偏时即时纠偏(回合边界采纳)。
            guard let text = (arguments["text"] as? String), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("缺少参数 text", true)
            }
            let wasActive = state.hasActiveModelCall
            // recordId 给了就纠偏那条(派发隔离任务也能接到);否则注入主会话当前回合。
            let interjectRecordID = (arguments["recordId"] as? String) ?? state.currentAgentTurnRecordID
            state.interjectCorrection(text, recordID: interjectRecordID)
            return (jsonText(["interjected": text, "wasActive": wasActive, "recordId": interjectRecordID ?? ""]), false)
        case "lingshu_get_chat":
            let limit = (arguments["limit"] as? Int) ?? 20
            return (jsonText(["messages": chatPayload(limit: limit)]), false)
        case "lingshu_get_trace":
            let limit = (arguments["limit"] as? Int) ?? 30
            return (jsonText(["trace": tracePayload(limit: limit)]), false)
        case "lingshu_stop":
            let wasActive = state.hasActiveModelCall
            let dispatched = await state.agentOrchestrator.activeDriveCount()
            state.cancelCurrentCall()
            return (jsonText(["stopped": wasActive || dispatched > 0, "mainTurn": wasActive, "dispatchedStopped": dispatched]), false)
        case "lingshu_autonomous":   // 驱动自主模式/常驻灵枢(等价独立运行面板)。args: action
            guard let action = (arguments["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return ("缺少参数 action(go_live|stop|pause|resume|arm|disarm)", true)
            }
            switch action {
            case "go_live":   state.goLiveAsStandingPerson()
            case "stop":      state.stopAutonomousRun()
            case "pause":     state.pauseAutonomousRun()
            case "resume":    state.resumeAutonomousRun()
            case "arm":       state.autonomousAutoReactArmed = true
            case "disarm":    state.autonomousAutoReactArmed = false
            default:          return ("未知 action:\(action)(go_live|stop|pause|resume|arm|disarm)", true)
            }
            return (jsonText([
                "ok": true,
                "action": action,
                "phase": state.autonomousRun.phase.rawValue,
                "standingPersonOnDuty": state.isStandingPersonOnDuty,
                "autoReactArmed": state.autonomousAutoReactArmed,
                "statusLine": state.autonomousRun.statusLine
            ]), false)
        case "lingshu_task_records":
            let limit = (arguments["limit"] as? Int) ?? 15
            let records = state.taskExecutionRecordLookup.prefix(max(1, limit)).map { r -> [String: Any] in
                [
                    "id": r.id, "title": r.title, "status": r.status.rawValue,
                    "messageCount": r.messages.count, "artifactCount": r.artifacts.count,
                    "feedback": state.taskRecordFeedback[r.id].map { $0 ? "up" : "down" } ?? "none"
                ]
            }
            return (jsonText(["records": Array(records)]), false)
        case "lingshu_task_detail":   // 取任务的 codex 式时间线(toolCall/toolResult/fileEdit+diff)+ 产出物
            guard let id = arguments["recordId"] as? String, let payload = taskDetailPayload(recordID: id) else {
                return ("缺少/无效参数 recordId", true)
            }
            return (jsonText(payload), false)
        case "lingshu_task_followup":
            // 窗口内追问续跑(等价底栏发送)。args: recordId, text。
            guard let id = arguments["recordId"] as? String, let text = arguments["text"] as? String else {
                return ("缺少参数 recordId / text", true)
            }
            state.submitTaskFollowup(text, recordID: id)
            return (jsonText(["ok": true, "recordId": id]), false)
        case "lingshu_task_feedback":
            // 设置任务反馈(等价 👍👎)。args: recordId, value(up/down/clear)。
            guard let id = arguments["recordId"] as? String, let value = arguments["value"] as? String else {
                return ("缺少参数 recordId / value", true)
            }
            state.setTaskFeedback(value == "up" ? true : (value == "down" ? false : nil), recordID: id)
            return (jsonText(["ok": true, "recordId": id, "value": value]), false)
        case "lingshu_undo_edit":
            // 撤销一次文件改动(等价 diff 卡"撤销")。args: recordId, messageId。
            guard let recordId = arguments["recordId"] as? String, let messageId = arguments["messageId"] as? String else {
                return ("缺少参数 recordId / messageId", true)
            }
            state.undoFileEdit(messageID: messageId, recordID: recordId)
            return (jsonText(["ok": true, "recordId": recordId, "messageId": messageId]), false)
        case "lingshu_attach":
            // 按路径加附件(等价 📎),走与主输入框同一 ingest 管线。args: path。
            guard let path = arguments["path"] as? String, FileManager.default.fileExists(atPath: path) else {
                return ("缺少/无效参数 path(文件不存在)", true)
            }
            state.ingestAttachment(at: URL(fileURLWithPath: path))
            return (jsonText(["ok": true, "pending": state.pendingAttachments.count]), false)
        case "lingshu_clear_attachments":
            // 清空待发送附件(等价逐个移除)。
            let count = state.pendingAttachments.count
            state.clearAttachments()
            return (jsonText(["ok": true, "cleared": count]), false)
        case "lingshu_clear_context":
            // 清空主对话上下文(新会话):停在飞回合 + 丢弃常驻会话 + 聊天/轨迹重置;任务线程与长期记忆保留。
            let hadSession = state.clearMainContext()
            return (jsonText(["ok": true, "hadSession": hadSession]), false)
        case "lingshu_acquire_resource":
            // 资源自获取:本地无→联网找模板/图标/字体/参考下载入库(测试/驱动用)。args: kind, query。
            guard let kind = arguments["kind"] as? String, let query = arguments["query"] as? String else {
                return ("缺少参数 kind / query", true)
            }
            let outcome = await LingShuState.acquireResource(kind: kind, query: query)
            return (jsonText(["result": outcome, "registryCount": LingShuResourceRegistry.shared.count]), false)
        case "lingshu_set_credential":   // 凭据写入加密库(AES-GCM 落盘,durable)。args: provider, token
            guard let provider = arguments["provider"] as? String,
                  let token = (arguments["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                return ("缺少参数 provider / token", true)
            }
            state.credentialStore.setAPIKey(token, forProvider: provider)
            let stored = (state.credentialStore.apiKey(forProvider: provider)?.isEmpty == false)
            return (jsonText(["ok": stored, "provider": provider, "tokenSuffix": String(token.suffix(6))]), false)
        case "lingshu_set_model":
            // 切换大脑(模型供应商/模型),选择持久化(跨重启)。不返显 key,只报是否已配置。
            guard let provider = (arguments["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty else {
                return ("缺少参数 provider", true)
            }
            state.applyModelProvider(provider)   // 设 provider/endpoint/默认 model,并从凭据库加载该 provider 的 key
            if let model = (arguments["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                state.modelName = model
            }
            return (jsonText([
                "ok": state.modelProvider == provider,
                "provider": state.modelProvider,
                "model": state.modelName,
                "endpoint": state.endpoint,
                "keyConfigured": !state.apiKey.isEmpty
            ]), false)
        case "lingshu_export_model_config":   // 口令加密导出脑/通道/密钥(换机/分享/开源安全);args: passphrase, path
            return state.controlExportModelConfig(passphrase: arguments["passphrase"] as? String, path: arguments["path"] as? String)
        case "lingshu_import_model_config":   // 一键导入口令加密配置 → 恢复并立即可用;args: passphrase, path
            return state.controlImportModelConfig(passphrase: arguments["passphrase"] as? String, path: arguments["path"] as? String)
        case "lingshu_run_brain_benchmark":   // 跑内置脑力测试,返回综合分(供脚本化 E2E)
            return await state.controlRunBrainBenchmark()
        case "lingshu_set_loop_variant":   // 切换核心循环引擎(classic|nested),持久化 + 清会话 holder 让下回合重建
            guard let raw = (arguments["variant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let variant = LingShuAgentLoopVariant(rawValue: raw) else {
                return ("缺少/非法参数 variant(应为 classic 或 nested)", true)
            }
            state.setAgentLoopVariant(variant)
            return (jsonText(["ok": state.agentLoopVariant == variant, "loopVariant": state.agentLoopVariant.rawValue]), false)
        case "lingshu_main_session":   // 读常驻主会话上下文尾部(验证子任务简报/纠正是否注入)。args: limit
            let limit = (arguments["limit"] as? Int) ?? 12
            let messages = await state.mainAgentSessionHolder?.messages ?? []
            let tail = messages.suffix(max(1, limit)).map { m -> [String: Any] in
                ["role": String(describing: m.role), "content": String(m.content.prefix(220)), "toolCalls": m.toolCalls.map(\.name)]
            }
            return (jsonText(["exists": state.mainAgentSessionHolder != nil, "messageCount": messages.count, "tail": tail]), false)
        case "meeting_start_capture":   // 采集帧直接喂 ASR:听会议 → 实时转写
            LingShuSystemAudioCapture.shared.onPCMChunk = { samples, sampleRate in
                LingShuMeetingASR.shared.appendPCM(samples, sampleRate: sampleRate)
            }
            let withASR = (arguments["transcribe"] as? Bool) ?? true
            do {
                try await LingShuSystemAudioCapture.shared.start()
                if withASR { LingShuMeetingASR.shared.start() }
                return (jsonText(["started": true, "transcribing": withASR, "status": LingShuSystemAudioCapture.shared.statusSnapshot]), false)
            } catch {
                return (jsonText(["started": false, "error": error.localizedDescription, "status": LingShuSystemAudioCapture.shared.statusSnapshot]), true)
            }
        case "meeting_stop_capture":
            await LingShuSystemAudioCapture.shared.stop()
            LingShuMeetingASR.shared.stop()
            return (jsonText(["stopped": true, "capture": LingShuSystemAudioCapture.shared.statusSnapshot, "asr": LingShuMeetingASR.shared.statusSnapshot]), false)
        case "meeting_capture_status":
            return (jsonText(LingShuSystemAudioCapture.shared.statusSnapshot), false)
        case "meeting_get_transcript":
            return (jsonText(LingShuMeetingASR.shared.statusSnapshot), false)
        case "meeting_converse_start":
            let msg = await state.startMeetingConversation()
            return (jsonText(["started": await state.isMeetingConversationActive, "message": msg]), false)
        case "meeting_converse_stop":
            let msg = await state.stopMeetingConversation()
            return (jsonText(["stopped": !(await state.isMeetingConversationActive), "message": msg]), false)
        case "agent_demo_start":
            return (jsonText(await runAgentDemo()), false)
        case "agent_resume":
            let id = (arguments["id"] as? String) ?? ""
            let answer = (arguments["answer"] as? String) ?? ""
            let result = await state.agentOrchestrator.resume(id: id, answer: answer)
            return (jsonText(["resumed": result != nil, "ledger": await ledgerPayload(), "pushes": await state.agentOrchestrator.pendingPushes()]), false)
        case "agent_ledger":
            return (jsonText(["ledger": await ledgerPayload(), "pushes": await state.agentOrchestrator.pendingPushes(), "running": await state.agentOrchestrator.runningCount(), "waiting": await state.agentOrchestrator.waitingCount()]), false)
        case "agent_run":
            guard let prompt = (arguments["prompt"] as? String), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("缺少参数 prompt", true)
            }
            return (jsonText(await runRealModelAgent(prompt: prompt)), false)
        case "lingshu_author_component":   // 调试:直接驱动真实自编外围流水线(不经模型选工具);args 即 author_component 入参
            let argsJSON = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let report = await state.authorComponent(argsJSON: argsJSON)
            return (jsonText(["report": report]), false)
        case "lingshu_call_authored_tool":   // 调试:直接调一条已上线 live 外围工具(证明真调通);args: tool, arguments
            guard let toolName = arguments["tool"] as? String else { return ("缺少参数 tool", true) }
            let toolArgs: String
            if let s = arguments["arguments"] as? String { toolArgs = s }
            else if let o = arguments["arguments"], let d = try? JSONSerialization.data(withJSONObject: o) { toolArgs = String(data: d, encoding: .utf8) ?? "{}" }
            else { toolArgs = "{}" }
            let liveTools = state.userSkillProvidedTools()
            guard let tool = liveTools.first(where: { $0.name == toolName }) else {
                return (jsonText(["found": false, "availableLiveTools": liveTools.map(\.name)]), false)
            }
            let out = await tool.handler(toolArgs)
            return (jsonText(["found": true, "output": out]), false)
        case "lingshu_approve_component":
            // 调试入口:主人审核通过一个隔离的工具/执行器组件(解除隔离=首肯首次运行)。args: id(组件id,如 actuator-xxx / authored-xxx)。
            guard let id = arguments["id"] as? String else { return ("缺少参数 id", true) }
            LingShuSkillAcquisition.clearQuarantine(skillID: "skill-\(id)")
            let ledgered = await state.recordIntegrationForApprovedComponent(componentID: id)   // §5:批准执行器=接入生效,记进知识图谱台账
            return (jsonText(["approved": true, "id": id, "integrationLedgered": ledgered]), false)
        case "lingshu_discover_devices":   // 调试:真实硬件枚举 + 驱动缺口分析
            return (jsonText(["report": await state.discoverDevices()]), false)
        case "lingshu_select_choice":   // 调试:模拟点选最新选项卡片(验证可点击→续接);args: label 可选
            guard let msg = state.chatMessages.last(where: { $0.choices != nil && $0.resolvedChoice == nil }),
                  let opts = msg.choices?.options, !opts.isEmpty else {
                return (jsonText(["selected": false, "reason": "无待选选项卡片"]), false)
            }
            let label = arguments["label"] as? String
            let opt = (label.flatMap { l in opts.first { $0.label == l } }) ?? opts[0]
            state.selectRouteChoice(opt, for: msg.id)
            return (jsonText(["selected": true, "label": opt.label]), false)
        case "lingshu_peripherals_scan":
            // 调试入口:刷新统一外设列表(汇集所有来源 + mDNS + 大脑自动归类),返回分组结果。
            await state.refreshPeripherals(autoClassify: (arguments["classify"] as? Bool) ?? true)
            let ps = state.peripheralHub.peripherals.map { p -> [String: Any] in
                ["id": p.id, "name": p.name, "transport": p.transport.rawValue, "group": p.displayGroup,
                 "controllable": p.isControllable, "access": p.classification?.access ?? "",
                 "note": p.classification?.note ?? p.statusLine]
            }
            return (jsonText(["count": ps.count, "localVolume": state.peripheralHub.localVolume, "hint": state.peripheralHub.hint, "summary": state.peripheralsSummary(), "peripherals": ps]), false)
        case "lingshu_peripheral_control":
            // 调试入口:控制一台本机可控外设。args: id(如 local.volume), action(mute/vol_up/vol_down/数字)。
            guard let id = arguments["id"] as? String, let action = arguments["action"] as? String else { return ("缺少参数 id/action", true) }
            let r = await state.peripheralHub.controlLocal(id, action)
            return (jsonText(["result": r, "localVolume": state.peripheralHub.localVolume]), false)
        case "lingshu_enable_sensor":
            // 调试入口:主人审核通过隔离的传感器型外围后启用它(解除隔离→注册/启用→进感知链)。args: id(组件id,如 sensor-xxx)。
            guard let id = arguments["id"] as? String else { return ("缺少参数 id", true) }
            let ok = state.approveAndEnableSensor(componentID: id)
            return (jsonText(["enabled": ok, "id": id]), false)
        case "lingshu_perceive":   // 调试:验证传感器数据进感知链、perceive 拉得到(采一拍后返回时间窗+外接信号+读数)
            let seconds = (arguments["seconds"] as? Double) ?? Double((arguments["seconds"] as? Int) ?? 10)
            state.samplePerceptionChainOnce()
            let window = state.perceptionChain.formattedWindow(seconds: max(1, min(60, seconds)))
            let readings = state.externalSensory.recentReadings.prefix(8).map { r -> [String: Any] in
                ["headline": r.headline, "sourceID": r.sourceID, "salience": r.salience, "detail": r.detail ?? ""]
            }
            return (jsonText([
                "perceiveWindow": window,
                "externalSignals": state.externalSignalsBrainInput(),
                "recentReadings": Array(readings),
                "masterEnabled": state.externalSensory.masterEnabled,
                "enabledSources": Array(state.externalSensory.enabledSourceIDs),
                "registeredSources": state.externalSensory.availableSources.map { ["id": $0.id, "name": $0.displayName, "channel": $0.channel.rawValue] }
            ]), false)
        default:
            return ("未知工具：\(name)", true)
        }
    }

    /// 用真实模型网关跑一次 agent 循环(带一个安全工具),验证「真模型大脑」驱动骨干。
    private func runRealModelAgent(prompt: String) async -> [String: Any] {
        let model = LingShuGatewayAgentModel(
            client: state.remoteModelClient,
            provider: state.modelProvider,
            model: state.modelName,
            endpoint: state.endpoint,
            protocolName: state.selectedModelPreset?.protocolName ?? "OpenAI 兼容",
            apiKey: state.apiKey,
            temperature: state.temperature,
            timeout: state.codexTimeoutSeconds
        )
        let timeTool = LingShuAgentTool(
            name: "get_current_time",
            description: "返回当前本机日期时间(ISO8601)。需要知道现在几点/今天日期时调用。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { _ in
            ISO8601DateFormatter().string(from: Date())
        }
        let system = "你是灵枢,一个会用工具的助手。需要外部信息(如当前时间)时调用对应工具,拿到结果后再用中文简洁作答。"
        let session = LingShuAgentSession(id: "mcp-agent-run", system: system, tools: [timeTool], model: model, maxTurns: 6)
        let result = await session.send(prompt)
        let invocations = await session.toolInvocations
        let turns = await session.turnsUsed
        let resultText: String
        switch result {
        case .completed(let text): resultText = text
        case .blocked(let q): resultText = "（卡住,等补充:\(q)）"
        case .maxTurnsReached(let t): resultText = "（达轮次上限:\(t)）"
        case .interrupted(let r): resultText = "（网络中断,已暂停:\(r)）"
        }
        return [
            "prompt": prompt,
            "model": "\(state.modelProvider) / \(state.modelName)",
            "finalAnswer": resultText,
            "toolsCalled": invocations,
            "turnsUsed": turns
        ]
    }

    /// 并发派生两条隔离子会话:A 直接完成,B 中途用 ask_user 卡住。展示真并行 + 卡住汇报。
    private func runAgentDemo() async -> [String: Any] {
        let subA = LingShuAgentSession(id: "sub-ppt", tools: [], model: LingShuScriptedAgentModel([
            .text("已生成《项目进度》汇报 PPT 初稿,共 8 页。")
        ]))
        let subB = LingShuAgentSession(id: "sub-crawler", tools: [], model: LingShuScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "ask_user", argumentsJSON: "{\"question\":\"爬虫的目标站点和频率是多少?\"}")]),
            .text("已按设定跑完爬虫,抓取 1240 条记录。")
        ]))
        // async let = 两条子会话真并行(各自独立 actor 会话)。
        async let ra = state.agentOrchestrator.spawn(id: "sub-ppt", objective: "做项目进度汇报PPT", session: subA)
        async let rb = state.agentOrchestrator.spawn(id: "sub-crawler", objective: "跑昨天的爬虫", session: subB)
        _ = await (ra, rb)
        return [
            "说明": "并发派生了两条隔离子会话;A 完成,B 卡住等你定。用 agent_resume 续接 B。",
            "ledger": await ledgerPayload(),
            "pushes": await state.agentOrchestrator.pendingPushes(),
            "running": await state.agentOrchestrator.runningCount(),
            "blockedIDs": await state.agentOrchestrator.blockedIDs()
        ]
    }

    private func ledgerPayload() async -> [[String: Any]] {
        await state.agentOrchestrator.ledger().map { entry in
            [
                "id": entry.id,
                "objective": entry.objective,
                "status": entry.status.rawValue,
                "summary": entry.summary,
                "blockedOn": entry.blockedOn ?? ""
            ]
        }
    }

    private func statusPayload() -> [String: Any] {
        [
            "coreState": state.coreStateDisplay,
            "loopPhase": state.loopPhase.rawValue,   // 理解中/规划中/执行中/验收中(空=空闲)
            "loopVariant": state.agentLoopVariant.rawValue,   // classic=经典连续 / nested=嵌套分阶段
            "trustScore": state.trustScore,             // 系统就绪度(模型连通/通道就绪/近期验收合成)
            "brainScore": ["score": state.brainScore.score, "completed": state.brainScore.completed, "fallbacks": state.brainScore.fallbacks, "brain": state.brainScore.brainID],   // 顶栏「脑力」:自主完成+1/兜底−1/换脑归零
            "missionTitle": state.missionTitle,
            "missionStatus": state.missionStatus,
            "autonomousPhase": state.autonomousRun.phase.rawValue,
            "autonomousObjective": state.autonomousRun.objective,
            "autonomousStatusLine": state.autonomousRun.statusLine,
            "standingPersonOnDuty": state.isStandingPersonOnDuty,
            "autoReactArmed": state.autonomousAutoReactArmed,
            "perceptionDigest": state.perceptionDigest,
            "perceptionDebug": state.perceptionDebugLine,
            "voiceListening": state.isListening,
            "voiceWake": state.voiceWakeListeningEnabled,
            "micSilentWarning": state.voiceManager?.micSilentWarning ?? "",   // 非空=麦克风没进音(权限/设备)
            "micLastInputAgoSec": state.voiceManager.map { Int(Date().timeIntervalSince($0.lastInputBufferAt)) } ?? -1,
            "previewState": [
                "isPresented": state.previewController.isPresented,
                "slideshow": state.previewController.slideshow,   // true=全屏演示模式
                "pageIndex": state.previewController.pageIndex,
                "pageCount": state.previewController.pageCount,
                "title": state.previewController.title
            ],
            "recentSpoken": Array(state.recentSpokenLines.suffix(14)),   // 演示文字稿(核验对得上画面)
            "chatCount": state.chatMessages.count,
            "taskRecordCount": state.taskExecutionRecords.count,
            "recentTaskRecords": state.taskExecutionRecords.prefix(8).map { record in
                [
                    "title": record.title,
                    "status": record.status.rawValue,
                    "artifactCount": record.artifacts.count,
                    "artifacts": record.artifacts.map { $0.location }
                ]
            }
        ]
    }

    /// 一条任务的 codex 式执行时间线 + 产出物 + 反馈(供 MCP inspect,免点开窗口看卡片)。
    private func taskDetailPayload(recordID: String) -> [String: Any]? {
        guard let record = state.taskExecutionRecordLookup.first(where: { $0.id == recordID }) else { return nil }
        return [
            "id": record.id,
            "title": record.title,
            "status": record.status.rawValue,
            "summary": record.summary,
            "feedback": state.taskRecordFeedback[record.id].map { $0 ? "up" : "down" } ?? "none",
            "plan": record.plan.map { ["title": $0.title, "status": $0.status.rawValue] },
            "designScore": record.designScore as Any,
            "codeChanges": record.codeChanges.map { cc in
                ["repoName": cc.repoName, "branch": cc.branch,
                 "files": cc.files.map { ["status": $0.status, "label": $0.label, "path": $0.path] }]
            } as Any,
            "artifacts": record.artifacts.map { ["title": $0.title, "location": $0.location, "operation": ($0.operation ?? .created).rawValue] },
            "messages": record.messages.map { message -> [String: Any] in
                var object: [String: Any] = ["id": message.id, "actor": message.actor, "role": message.role, "kind": message.kind.rawValue, "text": message.text]
                if let detail = message.detail { object["detail"] = Self.detailPayload(detail) }
                if let undone = message.undone { object["undone"] = undone }
                return object
            }
        ]
    }

    /// 结构化消息载荷序列化(toolCall/toolResult/fileEdit)——让 MCP 端能拿到命令/输出/diff 原文。
    private static func detailPayload(_ detail: LingShuTaskExecutionDetail) -> [String: Any] {
        switch detail {
        case let .toolCall(tool, summary, arguments):
            return ["type": "toolCall", "tool": tool, "summary": summary, "arguments": arguments]
        case let .toolResult(tool, success, output):
            return ["type": "toolResult", "tool": tool, "success": success, "output": output]
        case let .fileEdit(path, operation, added, removed, diff):
            return ["type": "fileEdit", "path": path, "operation": operation.rawValue, "added": added, "removed": removed, "diff": diff]
        }
    }

    private func chatPayload(limit: Int) -> [[String: Any]] {
        state.chatMessages.suffix(max(1, limit)).map { message in
            [
                "speaker": message.speaker,
                "text": message.text,
                "isUser": message.isUser,
                "isLoading": message.isLoading,
                "choices": message.choices?.options.map(\.label) ?? [],
                "createdAt": ISO8601DateFormatter().string(from: message.createdAt)
            ]
        }
    }

    private func tracePayload(limit: Int) -> [[String: Any]] {
        state.executionTrace.suffix(max(1, limit)).map { event in
            [
                "time": event.displayTime,
                "kind": String(describing: event.kind),
                "actor": event.actor,
                "title": event.title,
                "detail": event.detail
            ]
        }
    }

    // MARK: - 编解码辅助

    private func reply(id: Any?, result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func reply(id: Any?, error: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    /// 把工具结果对象序列化成文本(MCP tools/call 的 content.text)。
    private func jsonText(_ object: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
