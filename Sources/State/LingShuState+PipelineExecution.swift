import Foundation

/// 协同管线的执行辅助：任务级文件隔离、经验规则提炼、带工具的 agentic 调用、单阶段模型调用。
/// 从 LingShuState+Collaboration.swift 拆出，守住单文件聚焦一类职责。
@MainActor
extension LingShuState {
    // MARK: - 任务隔离 / 经验沉淀

    /// 任务级工作目录：codexWorkingDirectory/tasks/<id>/。并行任务各写各的子目录，
    /// 工具落盘物理隔离，互不污染。
    func makeTaskWorkingDirectory(for id: String) -> String {
        let safeID = id.replacingOccurrences(of: "/", with: "_")
        let dir = (codexWorkingDirectory as NSString)
            .appendingPathComponent("tasks")
        let taskDir = (dir as NSString).appendingPathComponent(safeID)
        try? FileManager.default.createDirectory(atPath: taskDir, withIntermediateDirectories: true)
        return taskDir
    }

    /// 提炼经验规则：把本轮"被打回的问题 + 如何修正"压成一条可复用规则写入语义库。
    /// 只在确实发生过修正时调用——对应"失败→核实→提炼规则"的复利路径。
    func distillExperienceRule(
        channel: PipelineChannel,
        token: UUID,
        userPrompt: String,
        expert: LingShuExpertProfile,
        critique: String,
        taskRecordID: String?
    ) async {
        var probe = LingShuStreamLatencyProbe()
        let prompt = """
        下面是一次任务评审中暴露的问题。请把它提炼成一条「以后做同类任务时应遵守的通用规则」，
        一句话、可执行、不绑定本次具体内容（不要出现本次的专有名词）。只输出这一句规则，不要解释。
        任务类型：\(expert.title)
        评审暴露的问题：
        \(String(critique.prefix(800)))
        """
        guard let rule = try? await pipelineModelCall(
            channel: channel,
            systemPrompt: "你负责把具体教训提炼成通用工程规则，输出一句话。",
            userPrompt: prompt,
            token: token,
            stageActor: "记忆",
            probe: &probe
        ), activePipelineToken == token else { return }

        let cleaned = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 6, cleaned.count <= 200 else { return }
        memoryService.rememberExperienceRule(domain: expert.title, rule: cleaned, source: "任务评审提炼")
        appendTaskRecordMessage(taskRecordID, actor: "记忆", role: "经验沉淀", kind: .memory, text: "已沉淀一条经验规则，下次同类任务会自动参考：\(cleaned)")
        appendTrace(kind: .system, actor: "记忆", title: "经验规则沉淀", detail: cleaned)
    }

    // MARK: - 管线模型调用

    struct PipelineChannel {
        var provider: String
        var model: String
        var endpoint: String
        var protocolName: String
        var apiKey: String
        var temperature: Double
        var timeout: TimeInterval
        var useStreaming: Bool
    }

    /// 单阶段模型调用：上下文严格任务内（不带聊天历史），按需把正文流式写入气泡。
    /// 带工具的执行调用：专家产出过程中可请求宿主执行真实动作（读写文件、列目录、
    /// 抓网页、跑命令），结果回传后继续——最多 4 个回合防失控。
    /// 工具调用与结果全部进任务执行记录可审计；run_command 受权限策略约束。
    func pipelineAgenticCall(
        channel: PipelineChannel,
        systemPrompt: String,
        userPrompt: String,
        token: UUID,
        stageActor: String,
        taskRecordID: String?,
        workingDirectory: String? = nil,
        streamInto bubbleID: UUID? = nil,
        probe: inout LingShuStreamLatencyProbe
    ) async throws -> String {
        // 外部 MCP 工具拼进工具目录（已发现的才列出，未配置则无额外开销）。
        let mcpTools = connectorRegistry.discoveredTools
        let mcpCatalog = mcpTools.isEmpty ? "" : "\n外部连接器工具（同样用【工具】行调用，tool 写工具名）：\n" + mcpTools.map { "- \($0.name)（\($0.serverName)）：\($0.description.prefix(80))" }.joined(separator: "\n")
        let resolvedWorkingDirectory = workingDirectory ?? codexWorkingDirectory
        // 明确告知工作目录 + shell 语法提醒：减少模型瞎猜路径（曾试图写 /tmp/pinchbench/…）
        // 和漏空格的坏命令（grep-n / ls-l / cat>）。
        let workingDirHint = """


        你的工作目录是：\(resolvedWorkingDirectory)
        - write_file 的 path 必须落在该目录内（用绝对路径，如 \(resolvedWorkingDirectory)/文件名），不要凭空假设其它路径。
        - run_command 在该目录下执行；命令必须语法正确，注意命令与参数之间留空格（要写 `ls -l`、`grep -n`、`cat > 文件`，不是 `ls-l`、`grep-n`、`cat>文件`）。
        """
        let toolSystemPrompt = systemPrompt + "\n\n" + toolExecutor.catalogPrompt + mcpCatalog + workingDirHint
        var conversation: [LingShuModelMessage] = []
        var currentPrompt = userPrompt
        let allowShell = !requireHumanApproval
        let workingDirectory = resolvedWorkingDirectory
        let mcpToolNames = Set(mcpTools.map(\.name))

        for turn in 0..<4 {
            let reply = try await pipelineModelCall(
                channel: channel,
                systemPrompt: toolSystemPrompt,
                userPrompt: currentPrompt,
                conversationMessages: conversation,
                token: token,
                stageActor: stageActor,
                streamInto: bubbleID,
                probe: &probe
            )
            let requests = LingShuToolCallParser.parse(reply)
            guard !requests.isEmpty, turn < 3 else {
                return LingShuToolCallParser.strippingToolLines(reply)
            }

            conversation.append(.init(role: "user", content: currentPrompt))
            conversation.append(.init(role: "assistant", content: reply))

            var resultLines: [String] = []
            for request in requests.prefix(3) {
                appendTaskRecordMessage(taskRecordID, actor: "工具", role: stageActor, kind: .agent, text: "请求执行 \(request.tool)：\(String(describing: request.arguments).prefix(200))")
                let mcpName = request.tool.hasPrefix("mcp:") ? String(request.tool.dropFirst(4)) : request.tool
                let result: LingShuToolResult
                if mcpToolNames.contains(mcpName), let client = connectorRegistry.client(forTool: mcpName) {
                    // 外部 MCP 工具：参数原样透传（字符串值），结果归一进任务记录。
                    result = await client.callTool(name: mcpName, arguments: request.arguments)
                } else {
                    result = await toolExecutor.execute(request, workingDirectory: workingDirectory, allowShell: allowShell)
                }
                appendTaskRecordMessage(taskRecordID, actor: "工具", role: "执行结果", kind: .agent, text: result.journalText)
                appendTrace(kind: .tool, actor: "工具", title: result.success ? "\(result.tool) 完成" : "\(result.tool) 失败", detail: String(result.output.prefix(180)))
                if result.tool == "write_file", result.success,
                   let path = request.arguments["path"] {
                    appendTaskRecordArtifact(taskRecordID, title: (path as NSString).lastPathComponent, location: path, producer: "工具执行")
                }
                resultLines.append("【工具结果】\(result.journalText)")
            }
            currentPrompt = resultLines.joined(separator: "\n") + "\n请基于工具结果继续完成交付物。"
        }
        return ""
    }

    func pipelineModelCall(
        channel: PipelineChannel,
        systemPrompt: String,
        userPrompt: String,
        conversationMessages: [LingShuModelMessage] = [],
        token: UUID,
        stageActor: String,
        streamInto bubbleID: UUID? = nil,
        probe: inout LingShuStreamLatencyProbe
    ) async throws -> String {
        let request = LingShuRemoteModelRequest(
            provider: channel.provider,
            model: channel.model,
            endpoint: channel.endpoint,
            protocolName: channel.protocolName,
            apiKey: channel.apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: channel.temperature,
            stream: channel.useStreaming,
            timeout: channel.timeout,
            continuationToken: nil,
            conversationMessages: conversationMessages
        )

        let reply: LingShuRemoteModelReply
        if channel.useStreaming {
            let parser = currentReplyAdapter.makeStreamParser()
            var localProbe = probe
            reply = try await remoteModelClient.stream(request) { [weak self] delta in
                Task { @MainActor in
                    guard let self, self.activePipelineToken == token else { return }
                    let event = parser.ingest(delta)
                    localProbe.observeDelta(hasContent: !event.contentDelta.isEmpty)
                    self.consumeModelStreamEvent(event, actor: stageActor, thinkingMessageID: bubbleID) { content in
                        if bubbleID != nil {
                            self.appendStreamingBubbleText(content, to: bubbleID)
                        }
                    }
                }
            } onHeartbeat: { [weak self] in
                Task { @MainActor in
                    guard let self, self.activePipelineToken == token else { return }
                    self.recordModelHeartbeat(source: stageActor, detail: "流式连接活跃。")
                }
            }
            probe = localProbe
            _ = parser.finish()
        } else {
            reply = try await remoteModelClient.send(request)
            probe.observeDelta(hasContent: true)
        }

        guard activePipelineToken == token, !Task.isCancelled else {
            throw CancellationError()
        }
        recordModelUsage(reply, stage: stageActor)
        return currentReplyAdapter.normalizedReplyText(reply.text)
    }
}
