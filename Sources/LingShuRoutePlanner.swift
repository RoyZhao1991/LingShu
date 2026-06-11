import Foundation

struct LingShuRoutePlanner {
    func routeSystemPrompt(permission: LingShuPermissionDecision) -> String {
        """
        你是“灵枢”的通用中枢人格和调度模型。你只做中枢判断、记忆理解、任务分派、权限裁决和最终答复草拟，不亲自扮演多个 agent。
        你必须先判断用户消息是否需要调用专家 agent 或任务运行时。

        输出要求：
        1. 只输出一个 JSON 对象，不要 Markdown，不要代码块，不要额外解释。
        2. 字段必须是：
           {
             "needsAgents": true 或 false,
             "summary": "一句话说明你的路由判断",
             "directAnswer": "如果 needsAgents=false，这里给用户的直接回答；否则可为空",
             "finalAnswer": "灵枢最终回复给用户的话，只能用灵枢统一口吻",
             "agents": [
               {
                 "agent": "\(LingShuCapabilityRole.promptChoiceList)",
                 "task": "分派给该 agent 的具体任务",
                 "mode": "规划|设计|执行|监工|纠偏|验收|待命",
                 "cadence": "本轮|实时|立即|提交后|3m|5m|7m|10m",
                 "rationale": "为什么需要这个 agent"
               }
             ]
           }
        3. 普通问答和解释类问题 needsAgents=false，并基于记忆直接回答。
        4. 用户要求写代码、脚本、页面、接口、爬虫、demo、程序、测试、修复、架构、部署、验收、Review、PPT、演示文稿、汇报材料或视觉设计时，needsAgents=true，必须包含“规划”“审议”“调度”，并按需加入设计、执行、监控、验证、安全、知识、记忆或路由。
        5. 不要列出所有 agent，只列本轮真正需要的能力节点。
        6. 如果用户的目标、对象、范围、交付物、权限边界或继续对象不明确，且无法从记忆中可靠判断，needsAgents=false，agents=[]，finalAnswer 只问必要的澄清问题；不要创建任务线程，不要盲目分派 agent。
        7. finalAnswer 不要提到底层模型、API Key、JSON、网关、CLI 等内部实现，除非用户明确询问技术接入。
        8. 如果用户问“你是谁”“你是什么”“你叫什么”“灵枢是谁”，needsAgents=false，finalAnswer 只需：“我是灵枢，有什么可以帮你的？”
        9. 不要自称通义千问、Qwen、MiniMax、GPT、Claude 或任何底层模型名称，你的身份只有“灵枢”。

        当前权限边界：\(permission.boundary)
        可用专家 agent：
        \(LingShuCapabilityRole.promptCatalog)
        """
    }

    var executionSystemPrompt: String {
        """
        你是灵枢调度的执行模型。请按任务运行时要求产出真实、可读、可交付的中文结果。
        当前 API 模型通道不能直接操作用户本机文件系统；除非宿主工具或外部 agent 明确返回结果，否则不要声称已经改文件、运行命令、部署或提交代码。
        交付时请包含：完成了什么、产出内容、验证方式或未验证原因、风险、自然下一步。
        最终只能以“灵枢”的统一口吻给用户简报，不要用多个 agent 分角色对话。
        """
    }

    func routeUserPrompt(userPrompt: String, memoryContext: String) -> String {
        """
        主线程压缩记忆：
        \(memoryContext)

        记忆使用规则：
        - 这些记忆只用于判断是否续接历史线程、是否需要创建任务线程、是否应加载执行记忆。
        - 不要把记忆当成已经完成的本轮事实。
        - 如果记忆提示用户在延续某个项目或主题，优先保持上下文连续性；如果没有命中，则按新任务处理。

        用户消息：
        \(userPrompt)
        """
    }

    func decodeRoutePayload(from rawReply: String) -> CodexRoutePayload? {
        guard let json = extractJSONObject(from: rawReply), let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CodexRoutePayload.self, from: data) else {
            return nil
        }
        return sanitizeRoutePayload(payload)
    }

    func modelGatewayErrorMessage(_ error: Error) -> String {
        if let gatewayError = error as? LingShuModelGatewayError {
            switch gatewayError {
            case .codexAuthRequiresBridge:
                return "Codex Auth 通道需要通过本机 Codex Bridge 调用。"
            case .missingAPIKey:
                return "当前模型供应商需要 API Key。"
            case .invalidEndpoint(let endpoint):
                return "模型网关地址无效：\(endpoint)。"
            case .hostAdapterRequired(let adapter):
                return "\(adapter) 需要宿主 SDK 适配器，当前不能直接 HTTP 调用。"
            case .requestFailed(let statusCode, let body):
                return "模型请求失败，HTTP 状态码 \(statusCode)。\(body.isEmpty ? "" : "返回：\(body)")"
            case .emptyResponse:
                return "模型返回为空。"
            case .unsupportedResponse:
                return "模型返回格式暂未识别。"
            }
        }
        return error.localizedDescription
    }

    private func extractJSONObject(from rawReply: String) -> String? {
        let trimmed = rawReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private func sanitizeRoutePayload(_ payload: CodexRoutePayload) -> CodexRoutePayload {
        var seenAgents = Set<String>()
        let sanitizedTasks = payload.agents.compactMap { task -> CodexAgentTask? in
            guard let agent = LingShuCapabilityRole.normalize(task.agent)?.rawValue,
                  !seenAgents.contains(agent) else {
                return nil
            }
            let trimmedTask = task.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTask.isEmpty else { return nil }
            seenAgents.insert(agent)
            return CodexAgentTask(
                agent: agent,
                task: trimmedTask,
                mode: task.mode?.trimmingCharacters(in: .whitespacesAndNewlines),
                cadence: task.cadence?.trimmingCharacters(in: .whitespacesAndNewlines),
                rationale: task.rationale?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let needsAgents = payload.needsAgents && !sanitizedTasks.isEmpty
        return CodexRoutePayload(
            needsAgents: needsAgents,
            agents: needsAgents ? sanitizedTasks : [],
            directAnswer: payload.directAnswer,
            finalAnswer: payload.finalAnswer,
            summary: payload.summary
        )
    }
}
