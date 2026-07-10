import Foundation

@MainActor
extension LingShuState {

    func diagnoseAgentFailureIfNeeded(
        plugin: LingShuAgentPlugin,
        failureText: String,
        recordID: String?
    ) async -> LingShuAgentFailureDiagnosis? {
        guard LingShuAgentPluginStore.unavailableReason(fromFailureText: failureText, agent: plugin) == nil else {
            return nil
        }
        let trimmed = failureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = Self.agentFailureDiagnosisPrompt(plugin: plugin, failureText: trimmed)
        let session = LingShuAgentSession(
            id: "agent-failure-\(UUID().uuidString.prefix(6))",
            system: Self.agentFailureDiagnosisSystemPrompt,
            tools: [],
            model: controlPlaneModelAdapter(.agentFailure, taskRecordID: recordID),
            maxTurns: 1
        )
        guard case .completed(let raw) = await session.send(prompt),
              let diagnosis = LingShuAgentFailureDiagnosis.parse(LingShuReasoningText.stripThinkTags(raw)) else {
            appendTrace(kind: .warning, actor: "agent状态理解", title: "分类失败",
                        detail: "未能把 \(plugin.displayName) 失败输出解析成结构化状态,保留原失败。")
            return nil
        }
        appendTrace(kind: .warning, actor: "agent状态理解", title: plugin.displayName, detail: diagnosis.traceSummary)
        return diagnosis
    }

    func normalizeAgentRunFailure(
        _ failureText: String,
        plugin: LingShuAgentPlugin,
        diagnosis: LingShuAgentFailureDiagnosis
    ) -> String {
        let reason = diagnosis.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if diagnosis.markPluginUnavailable {
            LingShuAgentPluginStore.markUnavailable(
                id: plugin.id,
                reason: reason.isEmpty ? "不可用" : reason
            )
            markAgentPluginCatalogChanged(agentID: plugin.id)
            return LingShuAgentPluginStore.unavailableMessage(
                agentName: plugin.displayName,
                reason: reason.isEmpty ? "不可用" : reason
            )
        }
        return LingShuAgentFailureDiagnosis.fallbackMessage(
            agentName: plugin.displayName,
            diagnosis: diagnosis,
            rawFailure: failureText
        )
    }

    private nonisolated static let agentFailureDiagnosisSystemPrompt = """
    你是外部 CLI agent 失败状态分类器。你只做归因,不解决原任务,不补写任务结果。
    输入会包含 agent 名称和一次失败输出。判断这次失败是「插件/账号/环境不可用」还是「agent 已启动但任务本身失败」。

    只输出一个 JSON 对象,不得输出 Markdown:
    {
      "category": "unavailable_auth | unavailable_quota | unavailable_install | unavailable_dependency | temporary_unavailable | task_failed | timeout | cancelled | unknown",
      "confidence": "high | medium | low",
      "mark_plugin_unavailable": true 或 false,
      "reason": "中文短原因,不超过 24 字",
      "user_message": "给用户看的中文状态,不超过 120 字",
      "retry_advice": "恢复建议,不超过 80 字"
    }

    分类规则:
    - 认证/登录/API key/账号/权限失效 => unavailable_auth,可 high 时 mark_plugin_unavailable=true。
    - 余额、额度、usage limit、billing、payment、credit、quota => unavailable_quota,可 high 时 mark_plugin_unavailable=true。
    - 找不到可执行文件、命令损坏、安装缺失 => unavailable_install,可 high 时 mark_plugin_unavailable=true。
    - node/python/runtime/library 等 agent 自身启动依赖缺失 => unavailable_dependency,可 high 时 mark_plugin_unavailable=true。
    - 429、服务繁忙、临时限流、网关抖动 => temporary_unavailable,mark_plugin_unavailable=false。
    - agent 成功启动,但用户任务里的代码/测试/命令/业务逻辑失败 => task_failed,mark_plugin_unavailable=false。
    - 软超时/长时间无输出 => timeout,mark_plugin_unavailable=false。
    - 用户取消/进程被手动终止 => cancelled,mark_plugin_unavailable=false。
    - 看不清就 unknown,confidence=low,mark_plugin_unavailable=false。
    - 只有高置信的 auth/quota/install/dependency 才允许 mark_plugin_unavailable=true;不要把普通任务失败误判成插件不可用。
    - user_message 不要泄露 token、key、路径里可能的秘密;不要复述大段原始输出。
    """

    private nonisolated static func agentFailureDiagnosisPrompt(
        plugin: LingShuAgentPlugin,
        failureText: String
    ) -> String {
        let evidence = LingShuAgentFailureDiagnosis.sanitizedEvidence(failureText)
        let aliases = plugin.allAliases.joined(separator: ", ")
        let payload: [String: Any] = [
            "agent": [
                "id": plugin.id,
                "display_name": plugin.displayName,
                "aliases": aliases,
                "role": plugin.role.rawValue
            ],
            "failure_output": evidence
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return """
        agent=\(plugin.displayName)
        failure_output=\(evidence)
        """
    }
}
