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
            // 停止在飞回合(等价任务窗口"停止"按钮)。
            let wasActive = state.hasActiveModelCall
            state.cancelCurrentCall()
            return (jsonText(["stopped": wasActive]), false)
        case "lingshu_autonomous":
            // 驱动自主模式/常驻灵枢(等价独立运行面板按钮),供脚本化验证完全接管态。args: action。
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
            // 列任务记录(热+冷),供挑选/inspect。
            let limit = (arguments["limit"] as? Int) ?? 15
            let records = state.taskExecutionRecordLookup.prefix(max(1, limit)).map { r -> [String: Any] in
                [
                    "id": r.id, "title": r.title, "status": r.status.rawValue,
                    "messageCount": r.messages.count, "artifactCount": r.artifacts.count,
                    "feedback": state.taskRecordFeedback[r.id].map { $0 ? "up" : "down" } ?? "none"
                ]
            }
            return (jsonText(["records": Array(records)]), false)
        case "lingshu_task_detail":
            // 取一条任务的 codex 式执行时间线(消息 + 结构化 detail:toolCall/toolResult/fileEdit+diff)+ 产出物。
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
        case "lingshu_set_credential":
            // 把凭据(如数据网关 VL token)写入灵枢配置数据库(AES-GCM 加密落盘,durable)。args: provider, token。
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
        case "lingshu_main_session":
            // 读常驻主会话上下文尾部(验证子任务简报/纠正是否注入)。args: limit。
            let limit = (arguments["limit"] as? Int) ?? 12
            let messages = await state.mainAgentSessionHolder?.messages ?? []
            let tail = messages.suffix(max(1, limit)).map { m -> [String: Any] in
                ["role": String(describing: m.role), "content": String(m.content.prefix(220)), "toolCalls": m.toolCalls.map(\.name)]
            }
            return (jsonText(["exists": state.mainAgentSessionHolder != nil, "messageCount": messages.count, "tail": tail]), false)
        case "meeting_start_capture":
            // 采集帧直接喂 ASR:听会议 → 实时转写。
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
