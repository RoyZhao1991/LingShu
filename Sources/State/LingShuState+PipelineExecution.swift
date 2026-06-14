import Foundation

/// 通用工具执行：5 个原语经 LingShuToolExecutor（带权限门控），外部 MCP 透传。
/// 统一 agent 循环的工具桥（agentBuiltinTools）经此执行；run_command 在需确认模式下弹中文授权框。
/// （旧的 plan→draft→review 协同管线与 pipeline* 系列调用已随启发式前置门退役，见架构速查手册 §5。）
@MainActor
extension LingShuState {
    /// 执行一次工具调用（MCP 透传 / 本机执行器），run_command 在需确认模式下弹授权框；统一记录到任务与轨迹。
    func runAgenticTool(
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
            // 外部 MCP 工具：原生 function-calling 用 arguments_json 信封承载真实参数
            // （描述符无 inputSchema）——在此唯一处解包成真实参数 dict 再透传，新旧路径共用。
            result = await client.callTool(name: mcpName, arguments: Self.unwrapMCPArguments(arguments))
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
        // run_command 产出的交付物(如 python 生成的 .pptx)不会被 write_file 自动登记——
        // 从命令与输出里抽出真实存在的交付型文件补登,让它出现在「任务产出文件」可预览/打开/定位(去重由 appendArtifact 负责)。
        if result.tool == "run_command", result.success {
            let haystack = (arguments["command"] ?? "") + "\n" + result.output
            for path in Self.extractRunCommandArtifacts(haystack, workingDirectory: workingDirectory)
            where FileManager.default.fileExists(atPath: path) {
                appendTaskRecordArtifact(taskRecordID, title: (path as NSString).lastPathComponent, location: path, producer: "命令产出")
            }
        }
        return result
    }

    /// 解包 MCP 工具参数：原生 function-calling 把真实参数塞在 arguments_json 信封里，
    /// 这里解析回真实参数 dict 透传给外部 server；非信封形式（文本协议回退）原样返回。
    nonisolated static func unwrapMCPArguments(_ arguments: [String: String]) -> [String: Any] {
        if let envelope = arguments["arguments_json"],
           let data = envelope.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return arguments
    }
}
