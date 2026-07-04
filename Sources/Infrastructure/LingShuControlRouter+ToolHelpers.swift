import Foundation

@MainActor
extension LingShuControlRouter {
    func submitPromptAndDescribe(
        text: String,
        source: LingShuDialogueInputSource,
        submit: () -> String
    ) async -> [String: Any] {
        let acceptedAt = Date()
        let beforeMessageIDs = Set(state.chatMessages.map(\.id))
        let beforeRecordIDs = Set(state.taskExecutionRecords.map(\.id))
        let immediateReply = submit()
        for _ in 0..<60 {
            let payload = submittedPromptPayload(
                text: text,
                source: source,
                acceptedAt: acceptedAt,
                immediateReply: immediateReply,
                beforeMessageIDs: beforeMessageIDs,
                beforeRecordIDs: beforeRecordIDs
            )
            let assistantID = payload["assistantMessageId"] as? String ?? ""
            let recordID = payload["recordId"] as? String ?? ""
            if !recordID.isEmpty || assistantID.isEmpty {
                return payload
            }
            if let assistantUUID = UUID(uuidString: assistantID),
               let assistant = state.chatMessages.first(where: { $0.id == assistantUUID }),
               !assistant.isLoading {
                return payload
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return submittedPromptPayload(
            text: text,
            source: source,
            acceptedAt: acceptedAt,
            immediateReply: immediateReply,
            beforeMessageIDs: beforeMessageIDs,
            beforeRecordIDs: beforeRecordIDs
        )
    }

    func submittedPromptPayload(
        text: String,
        source: LingShuDialogueInputSource,
        acceptedAt: Date,
        immediateReply: String,
        beforeMessageIDs: Set<UUID>,
        beforeRecordIDs: Set<String>
    ) -> [String: Any] {
        let newMessages = state.chatMessages.filter { !beforeMessageIDs.contains($0.id) }
        let userMessage = newMessages.last { $0.isUser }
        let userIndex = userMessage.flatMap { user in state.chatMessages.firstIndex(where: { $0.id == user.id }) }
        let assistantMessage: ChatMessage? = {
            if let userIndex {
                return state.chatMessages[(userIndex + 1)...].first(where: { !$0.isUser })
            }
            return newMessages.first(where: { !$0.isUser })
        }()
        let newRecord = state.taskExecutionRecords.first { !beforeRecordIDs.contains($0.id) }
        return [
            "submitted": text,
            "source": source.displayName,
            "acceptedAt": ISO8601DateFormatter().string(from: acceptedAt),
            "immediateReply": immediateReply,
            "userMessageId": userMessage?.id.uuidString ?? "",
            "assistantMessageId": assistantMessage?.id.uuidString ?? "",
            "recordId": assistantMessage?.taskRecordID ?? newRecord?.id ?? "",
            "createdRecordIds": state.taskExecutionRecords
                .filter { !beforeRecordIDs.contains($0.id) }
                .map(\.id)
        ]
    }

    /// 用真实模型网关跑一次 agent 循环(带一个安全工具),验证「真模型大脑」驱动骨干。
    func runRealModelAgent(prompt: String) async -> [String: Any] {
        let model = LingShuGatewayAgentModel(
            client: state.remoteModelClient,
            provider: state.modelProvider,
            model: state.modelName,
            endpoint: state.endpoint,
            protocolName: state.selectedModelPreset?.protocolName ?? "OpenAI 兼容",
            apiKey: state.apiKey,
            temperature: state.temperature,
            timeout: state.modelTimeoutSeconds
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
    func runAgentDemo() async -> [String: Any] {
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

    func waitForAttachmentIngestion(path: String) async -> (ready: Bool, status: String) {
        let url = URL(fileURLWithPath: path)
        for _ in 0..<80 {   // 最长约 8 秒:文本/PDF/PPT 本地抽取通常很快;图片云感知慢时给清晰状态。
            if let attachment = state.pendingAttachments.last(where: { $0.localURL?.path == url.path }) {
                if !attachment.extractedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return (true, attachment.status ?? "就绪")
                }
                if let status = attachment.status, !status.contains("解析中") {
                    return (false, status)
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return (false, "解析超时")
    }
}
