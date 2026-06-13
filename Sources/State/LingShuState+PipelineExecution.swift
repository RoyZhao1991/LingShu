import Foundation

/// 一个子任务的 acting agent 全程共用的对话载体（草稿 + 所有重做共享）。
///
/// 把"用完即弃的短 agent"变成"长命、持续记忆的 agent"：每次工具调用、每条报错都留在这条
/// 不断增长的对话里，重做时模型带着"我试过什么、怎么失败的"全部历史继续——撞墙就换方法，
/// 而不是从零再撞同一堵墙。这是对齐并超越 Codex 连续 agent 循环的载体（评审仍由独立子 agent 把关）。
final class LingShuAgentThread {
    var messages: [LingShuModelMessage] = []
}

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
        thread: LingShuAgentThread,
        maxToolTurns: Int = 16,
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
        - 任务需要在本机真实执行（跑脚本、安装依赖、转换/生成文件、运行 demo、落地产物）时，**直接用 run_command 发起真实命令**——宿主会弹窗请用户授权，获批后即真实执行。
        - **不要因为担心权限就跳过执行、改成给用户一段"你自己存成 xx.py 跑一下"的脚本**：那是降级、不是完成。该执行就发 run_command，把授权交给用户决定。若用户拒绝，你才退而给出可手动运行的方案。
        """
        let toolSystemPrompt = systemPrompt + "\n\n" + toolExecutor.catalogPrompt + mcpCatalog + workingDirHint
        let allowShell = !requireHumanApproval
        let workingDirectory = resolvedWorkingDirectory
        let mcpToolNames = Set(mcpTools.map(\.name))

        // 原生 function-calling：内建 5 个工具 + 已发现的 MCP 工具的结构化 schema。
        // 系统提示里仍保留文本 `【工具】` 目录作兜底——供应商若不支持 tools 字段也能退回文本协议。
        let toolDefinitions = LingShuFunctionCallingCatalog.builtin
            + mcpTools.map { LingShuFunctionCallingCatalog.definition(forMCPTool: $0.name, description: $0.description) }

        // 长命 acting agent：首次进来播种 system+user；之后是**同一条对话续接**——
        // 保留全部工具调用与报错历史，模型据此"换个方法再试"，对齐并超越 Codex。
        if thread.messages.isEmpty {
            thread.messages = [
                .init(role: "system", content: toolSystemPrompt),
                .init(role: "user", content: userPrompt)
            ]
        } else {
            thread.messages.append(.init(role: "user", content: userPrompt))
        }

        for turn in 0..<maxToolTurns {
            let reply = try await pipelineToolTurn(
                channel: channel,
                conversation: thread.messages,
                tools: toolDefinitions,
                token: token,
                stageActor: stageActor,
                probe: &probe
            )
            let replyText = currentReplyAdapter.normalizedReplyText(reply.text)

            // 原生 tool_calls 优先；模型没用原生就回退解析文本 `【工具】` 行（鲁棒兜底）。
            let nativeCalls = reply.toolCalls
            let textRequests = nativeCalls.isEmpty ? LingShuToolCallParser.parse(replyText) : []

            guard (!nativeCalls.isEmpty || !textRequests.isEmpty), turn < maxToolTurns - 1 else {
                let finalText = LingShuToolCallParser.strippingToolLines(replyText)
                if let bubbleID { appendStreamingBubbleText(finalText, to: bubbleID) }
                // 收稿也进对话历史，后续重做轮次能看到"我上一版交了什么"。
                thread.messages.append(.init(role: "assistant", content: replyText))
                return finalText
            }

            // 助手回合进会话（原生调用带 tool_calls，便于多轮对账）。
            thread.messages.append(.init(
                role: "assistant",
                content: replyText,
                toolCalls: nativeCalls.isEmpty ? nil : nativeCalls
            ))

            // 统一成 (调用id?, 工具名, 参数) 三元组：原生走 tool 结果消息，文本回退走 【工具结果】 行。
            let invocations: [(id: String?, tool: String, arguments: [String: String])] = nativeCalls.isEmpty
                ? Array(textRequests.prefix(3)).map { (nil, $0.tool, $0.arguments) }
                : Array(nativeCalls.prefix(3)).map { ($0.id, $0.name, $0.argumentDictionary) }

            var textResultLines: [String] = []
            for invocation in invocations {
                let result = await runAgenticTool(
                    tool: invocation.tool,
                    arguments: invocation.arguments,
                    stageActor: stageActor,
                    taskRecordID: taskRecordID,
                    workingDirectory: workingDirectory,
                    mcpToolNames: mcpToolNames,
                    baseAllowShell: allowShell
                )
                if let callID = invocation.id {
                    thread.messages.append(.init(role: "tool", content: result.journalText, toolCallID: callID))
                } else {
                    textResultLines.append("【工具结果】\(result.journalText)")
                }
            }

            if !textResultLines.isEmpty {
                thread.messages.append(.init(
                    role: "user",
                    content: textResultLines.joined(separator: "\n") + "\n请基于工具结果继续完成交付物。"
                ))
            }
        }
        return ""
    }

    /// 单次工具回合：非流式调用模型并下发原生 tools；供应商若拒绝 tools 字段，去掉 tools 重试一次（回退文本协议）。
    private func pipelineToolTurn(
        channel: PipelineChannel,
        conversation: [LingShuModelMessage],
        tools: [LingShuToolDefinition],
        token: UUID,
        stageActor: String,
        probe: inout LingShuStreamLatencyProbe
    ) async throws -> LingShuRemoteModelReply {
        func request(tools: [LingShuToolDefinition]) -> LingShuRemoteModelRequest {
            LingShuRemoteModelRequest(
                provider: channel.provider,
                model: channel.model,
                endpoint: channel.endpoint,
                protocolName: channel.protocolName,
                apiKey: channel.apiKey,
                systemPrompt: "",
                userPrompt: "",
                temperature: channel.temperature,
                stream: false,
                timeout: channel.timeout,
                continuationToken: nil,
                conversationMessages: conversation,
                tools: tools
            )
        }

        // 非流式 tool 回合没有流式心跳——主动喂一次，否则长 agent burst 会被 180s 看门狗误杀（明明在干活）。
        recordModelHeartbeat(source: stageActor, detail: "执行模型回合推进中（工具调用）。")

        let reply: LingShuRemoteModelReply
        do {
            reply = try await remoteModelClient.send(request(tools: tools))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !tools.isEmpty else { throw error }
            // tools 字段被供应商拒绝：去掉重试，模型改用系统提示里的文本 `【工具】` 协议。
            reply = try await remoteModelClient.send(request(tools: []))
        }

        probe.observeDelta(hasContent: true)
        guard activePipelineToken == token, !Task.isCancelled else { throw CancellationError() }
        recordModelUsage(reply, stage: stageActor)
        return reply
    }

    /// 执行一次工具调用（MCP 透传 / 本机执行器），run_command 在需确认模式下弹授权框；统一记录到任务与轨迹。
    private func runAgenticTool(
        tool: String,
        arguments: [String: String],
        stageActor: String,
        taskRecordID: String?,
        workingDirectory: String,
        mcpToolNames: Set<String>,
        baseAllowShell: Bool
    ) async -> LingShuToolResult {
        appendTaskRecordMessage(taskRecordID, actor: "工具", role: stageActor, kind: .agent, text: "请求执行 \(tool)：\(String(describing: arguments).prefix(200))")
        // 工具执行（brew install / 长命令）也是真实活动——执行前后各喂一次心跳，别让 180s 看门狗误判失联。
        recordModelHeartbeat(source: "工具", detail: "正在执行 \(tool)。")
        // 长命令（python-pptx 生成、LibreOffice 转 PDF、装依赖）可能跑几十秒到几分钟：
        // 执行期间每 25s 续一次心跳，否则命令跑到一半就被 180s 看门狗误杀（"疑似命令未跑完"的真因）。
        let heartbeatKeepalive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { break }
                self?.recordModelHeartbeat(source: "工具", detail: "\(tool) 仍在执行…")
            }
        }
        defer { heartbeatKeepalive.cancel() }
        let mcpName = tool.hasPrefix("mcp:") ? String(tool.dropFirst(4)) : tool
        let result: LingShuToolResult
        if mcpToolNames.contains(mcpName), let client = connectorRegistry.client(forTool: mcpName) {
            // 外部 MCP 工具：参数原样透传（字符串值），结果归一进任务记录。
            result = await client.callTool(name: mcpName, arguments: arguments)
        } else {
            // 高风险动作（run_command）在需人工确认模式下：弹中文授权框等用户裁决，
            // 用户点「本次允许 / 完全授权」才放行——不再直接拒绝、逼模型降级成"给你段脚本自己跑"。
            var effectiveAllowShell = baseAllowShell || sessionShellAlwaysAllowed
            if tool == "run_command", !effectiveAllowShell {
                let decision = await requestShellApproval(
                    command: arguments["command"] ?? "",
                    workingDirectory: workingDirectory,
                    taskRecordID: taskRecordID
                )
                effectiveAllowShell = (decision != .deny)
            }
            result = await toolExecutor.execute(
                .init(tool: tool, arguments: arguments),
                workingDirectory: workingDirectory,
                allowShell: effectiveAllowShell
            )
        }
        recordModelHeartbeat(source: "工具", detail: "\(result.tool) 执行完成。")
        appendTaskRecordMessage(taskRecordID, actor: "工具", role: "执行结果", kind: .agent, text: result.journalText)
        appendTrace(kind: .tool, actor: "工具", title: result.success ? "\(result.tool) 完成" : "\(result.tool) 失败", detail: String(result.output.prefix(180)))
        if result.tool == "write_file", result.success, let path = arguments["path"] {
            appendTaskRecordArtifact(taskRecordID, title: (path as NSString).lastPathComponent, location: path, producer: "工具执行")
        }
        return result
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
