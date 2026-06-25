import Foundation

@MainActor
extension LingShuState {
    /// 通用工具桥:把既有通用原语经 LingShuToolExecutor 带权限门控映射成 agent 工具。
    func agentBuiltinTools(
        recordIDProvider: @escaping @MainActor @Sendable () -> String?,
        executionPolicy: LingShuAgentExecutionPolicy = .standard
    ) -> [LingShuAgentTool] {
        let workingDir = agentWorkingDirectory
        let allowShell: Bool
        switch executionPolicy {
        case .standard:       allowShell = developmentPhaseFullAccess || !requireHumanApproval || sessionShellAlwaysAllowed
        case .readOnly:       allowShell = false
        case .autoAllowShell: allowShell = true
        }
        let mcpTools = executionPolicy == .readOnly ? [] : connectorRegistry.discoveredTools
        let mcpToolNames = Set(mcpTools.map(\.name))
        let bridge: @MainActor @Sendable (String, [String: String]) async -> String = { [weak self] tool, args in
            guard let self else { return "执行环境不可用" }
            let recordID = recordIDProvider()
            self.missionTitle = "执行中：\(Self.toolDisplayName(tool))"
            defer { self.missionTitle = self.currentActivityLabel }
            let result = await self.runAgenticTool(
                tool: tool,
                arguments: args,
                stageActor: "Agent循环",
                taskRecordID: recordID,
                workingDirectory: workingDir,
                mcpToolNames: mcpToolNames,
                baseAllowShell: allowShell
            )
            return result.modelText
        }
        let builtinDefs = executionPolicy == .readOnly
            ? LingShuFunctionCallingCatalog.builtin.filter { ["read_file", "list_directory", "fetch_url"].contains($0.name) }
            : LingShuFunctionCallingCatalog.builtin
        let builtinTools = builtinDefs.map { def in
            LingShuAgentTool(name: def.name, description: def.description, parametersJSON: Self.schemaJSON(for: def)) { argsJSON in
                await bridge(def.name, Self.parseArgs(argsJSON))
            }
        }
        let externalTools = mcpTools.map { descriptor -> LingShuAgentTool in
            let def = LingShuFunctionCallingCatalog.definition(forMCPTool: descriptor.name, description: descriptor.description)
            return LingShuAgentTool(name: def.name, description: def.description, parametersJSON: Self.schemaJSON(for: def)) { argsJSON in
                await bridge(def.name, Self.parseArgs(argsJSON))
            }
        }
        let skillTools = executionPolicy == .readOnly ? [] : [applySkillTool(), applyPatchAgentTool(recordIDProvider: recordIDProvider, workingDirectory: workingDir)]
        let pluginTools = executionPolicy == .readOnly ? [] : userSkillProvidedTools()
        let recordedLocalKnowledgeTools = localKnowledgeTools().map {
            recordedAgentTool($0, recordIDProvider: recordIDProvider)
        }
        return builtinTools + externalTools + skillTools + pluginTools + recordedLocalKnowledgeTools + [listCapabilitiesTool(), selfInspectTool()]
            + (executionPolicy == .readOnly ? [] : agentPluginTools(recordIDProvider: recordIDProvider))   // 通用 register_agent/run_agent:任何 CLI agent 当插件接入,零硬编码;委托的 agent 作为任务时间线独立命名参与方
    }

    /// 给非原语 Agent 工具补一层结构化执行记录。
    func recordedAgentTool(
        _ tool: LingShuAgentTool,
        recordIDProvider: @escaping @MainActor @Sendable () -> String?
    ) -> LingShuAgentTool {
        LingShuAgentTool(name: tool.name, description: tool.description, parametersJSON: tool.parametersJSON) { [weak self] argsJSON in
            guard let self else { return await tool.handler(argsJSON) }
            let args = Self.parseArgs(argsJSON)
            let recordID = await MainActor.run { recordIDProvider() }
            let summary = LingShuTaskMessageFormatting.toolCallSummary(tool: tool.name, arguments: args)
            await MainActor.run {
                self.appendTaskRecordMessage(
                    recordID, actor: "工具", role: "Agent循环", kind: .agent, text: summary,
                    detail: .toolCall(tool: tool.name, summary: summary, arguments: LingShuTaskMessageFormatting.prettyArguments(args))
                )
            }
            let output = await tool.handler(argsJSON)
            let success = Self.agentToolOutputLooksSuccessful(output)
            await MainActor.run {
                self.appendTaskRecordMessage(
                    recordID, actor: "工具", role: "执行结果", kind: .agent,
                    text: success ? "\(tool.name) 完成" : "\(tool.name) 未完成",
                    detail: .toolResult(tool: tool.name, success: success, output: output)
                )
            }
            return output
        }
    }

    nonisolated static func agentToolOutputLooksSuccessful(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return true }
        let hardFailures = [
            "执行环境不可用", "缺少 ", "目录不存在", "不是文件夹", "尚未指定",
            "没指定", "没读到", "没找到图片", "未授权", "需要授权", "需系统",
            "permission denied", "not permitted", "operation not permitted", "error:", "失败"
        ]
        return !hardFailures.contains { text.contains($0.lowercased()) }
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

    /// 阻塞工具:loop 截获,不真正执行(handler 仅占位)。
    nonisolated static func askUserTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "ask_user",
            description: "信息不足、无法继续时,向用户提一个明确问题。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"要问用户的问题\"}},\"required\":[\"question\"]}"
        ) { _ in "" }
    }

    /// 主动出声工具:用于演示/汇报/会议里逐句讲、实时应答。
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
                self?.recordSpokenLine(text)
            }
            await voice.awaitPlaybackDone()
            return "(已说完:\(text.prefix(40)))"
        }
    }

    nonisolated static func jsonField(_ json: String, _ key: String) -> String? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}
