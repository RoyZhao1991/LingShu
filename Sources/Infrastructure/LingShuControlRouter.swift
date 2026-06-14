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
            let reply = state.submitTextInput(text, source: source)
            return (jsonText(["submitted": text, "immediateReply": reply]), false)
        case "lingshu_get_chat":
            let limit = (arguments["limit"] as? Int) ?? 20
            return (jsonText(["messages": chatPayload(limit: limit)]), false)
        case "lingshu_get_trace":
            let limit = (arguments["limit"] as? Int) ?? 30
            return (jsonText(["trace": tracePayload(limit: limit)]), false)
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
