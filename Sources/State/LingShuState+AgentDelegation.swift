import Foundation

/// 把 Codex / Claude Code 作为**可委托的外部 agent 工具**交给大脑——不是由一个确定性 resolver 替大脑选,
/// 而是把「现在有哪些 agent 可外包」放进工具清单,**大脑自己判断**这段活要不要外包、外包给谁(maker),
/// 以及要不要让另一个做独立复核(checker)。可用性实时判:Codex 登录 / Claude 装了,才出现在清单里。
@MainActor
extension LingShuState {

    /// 当前可用的委托工具集(只读策略不给——委托=做实事)。
    func agentDelegationTools(executionPolicy: LingShuAgentExecutionPolicy) -> [LingShuAgentTool] {
        guard executionPolicy != .readOnly else { return [] }
        var tools: [LingShuAgentTool] = []
        if codexAuthStatus == "已登录" { tools.append(delegateToCodexTool()) }
        if ClaudeBridge.isAvailable() { tools.append(delegateToClaudeTool()) }
        return tools
    }

    func delegateToCodexTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "delegate_to_codex",
            description: "把一段**仓库内编码/工程活整体外包给 Codex**(外部编码 agent,在工作目录里自主读改跑测,擅长重型实现/重构/把测试修到绿)。你给清目标即可,它自己规划执行并返回结果与产物。何时用:这段活很重、纯编码、值得交给更强的编码 agent;做完你可再让 delegate_to_claude 做跨厂商复核。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"objective\":{\"type\":\"string\",\"description\":\"要 Codex 达成的自足目标(说清做什么、产出物/验收要求)\"}},\"required\":[\"objective\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            let objective = (Self.jsonField(argsJSON, "objective") ?? argsJSON).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else { return "objective 为空,没法委托。" }
            return await self.runDelegatedCodex(objective: objective)
        }
    }

    func delegateToClaudeTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "delegate_to_claude",
            description: "把一段子任务外包给 **Claude Code**(外部 agent),或让它做**独立审查/复核**——跨厂商第二视角,特别适合验收 Codex 或你自己写的代码/产物(maker≠checker 真跨源)。你给清目标(做某事,或『复核这段产物:…』)即可。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"objective\":{\"type\":\"string\",\"description\":\"要 Claude 达成的目标,或要复核的对象与判据\"}},\"required\":[\"objective\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用。" }
            let objective = (Self.jsonField(argsJSON, "objective") ?? argsJSON).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else { return "objective 为空,没法委托。" }
            return await self.runDelegatedClaude(objective: objective)
        }
    }

    /// 委托 Codex:复用 `LingShuCodexAgentSession`(codex exec,取消透传)。在 MainActor 读配置,await 时释放 MainActor。
    func runDelegatedCodex(objective: String) async -> String {
        guard codexAuthStatus == "已登录" else { return "Codex 未登录,无法委托(请先在系统配置里登录 Codex)。" }
        appendTrace(kind: .tool, actor: "委托·Codex", title: "外包给 Codex", detail: String(objective.prefix(60)))
        let session = LingShuCodexAgentSession(
            cliPath: codexCLIPath, modelName: "", workingDirectory: codexWorkingDirectory,
            permissionMode: codexPermissionMode, timeout: codexTimeoutSeconds, fastMode: codexFastMode)
        let result = await session.send(objective)
        switch result {
        case .completed(let text):       return "【Codex 已完成委托】\n\(text)"
        case .interrupted(let reason):   return "【Codex 委托未完成】\(reason)（你可自己接着做,或换 delegate_to_claude / 自己干）"
        case .blocked(let q):            return "【Codex 需要更多信息】\(q)"
        case .maxTurnsReached(let t):    return "【Codex 达步数上限】\(t)"
        }
    }

    /// 委托 Claude Code:`claude -p` 非交互。阻塞调用放后台线程,取消经句柄透传子进程。
    func runDelegatedClaude(objective: String) async -> String {
        appendTrace(kind: .tool, actor: "委托·Claude", title: "外包给 Claude Code", detail: String(objective.prefix(60)))
        let wd = codexWorkingDirectory
        let timeout = max(codexTimeoutSeconds, 300)   // 编码委托可能久,给足
        let handle = CodexExecutionHandle()
        let result: ClaudeReplyResult = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ClaudeReplyResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: ClaudeBridge.execReply(
                        prompt: objective, workingDirectory: wd, timeout: timeout, cancellation: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
        switch result {
        case .success(let text):     return "【Claude Code 已完成委托】\n\(text)"
        case .failure(let reason):   return "【Claude 委托未完成】\(reason)（你可自己接着做,或换 delegate_to_codex / 自己干）"
        }
    }
}
