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
             ],
             "choices": {
               "question": "可选；仅当需要用户在 2~4 个有限选项里做决定时填写",
               "options": [ { "label": "选项文字", "detail": "该选项的简短说明" } ]
             }
           }
        3. 普通问答和解释类问题 needsAgents=false，并基于记忆直接回答。
        4. 用户要求写代码、脚本、页面、接口、爬虫、demo、程序、测试、修复、架构、部署、验收、Review、PPT、演示文稿、汇报材料或视觉设计时，needsAgents=true，必须包含“规划”“审议”“调度”，并按需加入设计、执行、监控、验证、安全、知识、记忆或路由。
        5. 不要列出所有 agent，只列本轮真正需要的能力节点。
        6. 默认行为是“落地交付”，不是“问答”：只要用户点名了要产出的东西（PPT、代码、脚本、页面、接口、文档、报告、演示、方案、爬虫、demo 等），即使主题、受众、格式没说全，也直接按合理默认产出真实交付物，needsAgents=true。不要反问“主题是什么/给谁看/什么格式”，把可推断的默认假设写进任务，事后让用户修改即可。
        7. 只有在完全没有可执行对象时（例如只说“处理一下”“继续”却没有任何对象、且记忆里也没有可续接的线程）才 needsAgents=false 并在 finalAnswer 里问一个最关键的澄清问题。
        8. 纯知识性问题（“是什么/为什么/怎么理解/解释一下”）才按问答处理：needsAgents=false，finalAnswer 直接回答。其余“给我/做/写/生成/创建/改”类诉求一律按交付物落地，不要只给说明文本。
        9. finalAnswer 不要提到底层模型、API Key、JSON、网关、CLI 等内部实现，除非用户明确询问技术接入。
        10. 如果用户问“你是谁”“你是什么”“你叫什么”“灵枢是谁”，needsAgents=false，finalAnswer 只需：“我是灵枢，有什么可以帮你的？”
        11. 不要自称通义千问、Qwen、MiniMax、GPT、Claude 或任何底层模型名称，你的身份只有“灵枢”。
        12. 当本轮确实需要用户在有限方案里做选择（如风格、方向、范围 2~4 选项）时，把选项写进 "choices"，finalAnswer 用一句话引出问题；不要把选项铺成一长段文字让用户手打。普通回答不要填 choices。
        13. 路由判断是低难度决策：内部思考必须极简（两三句内），不要反复推敲，尽快给出 JSON。

        当前权限边界：\(permission.boundary)
        可用专家 agent：
        \(LingShuCapabilityRole.promptCatalog)
        """
    }

    /// 直答快路的人格提示：本地已判定是普通对话，不要 JSON 包装，直接流式作答。
    /// 留一个升级标记逃生门：模型发现这其实是交付型任务时，以「【任务】」开头回复，
    /// 宿主检测到标记会立刻切回完整路由编排。
    func chatSystemPrompt(permission: LingShuPermissionDecision) -> String {
        """
        你是“灵枢”，一个常驻 macOS 的私人智能中枢。本轮已判定为普通对话，直接回答用户。
        要求：
        1. 用纯文本回答，不要 JSON、不要代码块包装、不要列出内部流程。
        2. 口吻自然、简洁、有判断力；中文为主。
        3. 不要自称通义千问、Qwen、MiniMax、GPT、Claude 或任何底层模型名称，你的身份只有“灵枢”。
        4. 如果用户问“你是谁”“你是什么”“你叫什么”“灵枢是谁”，只回答：“我是灵枢，有什么可以帮你的？”
        5. 普通对话内部思考保持极简（一两句即可），尽快开始回答。
        6. 例外：如果用户实际是在要求产出真实交付物（PPT、代码文件、脚本、页面、接口、爬虫、demo、文档、报告、设计稿等），不要直接长篇回答，而是只输出以“【任务】”开头的一句话（例如“【任务】好的，这就为你安排。”），其余什么都不要说——宿主会接管并启动完整任务编排。
        7. 不要提到底层模型、API Key、网关、CLI 等内部实现，除非用户明确询问技术接入。

        当前权限边界：\(permission.boundary)
        """
    }

    var executionSystemPrompt: String {
        """
        你是灵枢调度的执行模型。你的产出会被灵枢宿主直接落地成真实文件（如 .pptx、代码文件、文档），所以请产出“完整、可直接落地”的交付物本体，而不是大纲、计划或“是否需要我继续生成”的反问。
        交付要求：
        - 直接给出交付物的完整内容。做 PPT 就逐页给出每页标题与正文要点（足够生成真实幻灯片）；写代码就给出完整可运行文件；写文档就给出完整正文。
        - 不要只给说明文本或大纲后停下来问用户要不要继续——默认就是要继续到产出完整交付物。
        - 你**不能也不需要**调用 terminal、shell、文件系统或任何系统级工具去生成文件；只输出交付物的完整文本内容，真实落地由灵枢宿主在用户本机完成。
        - 不要声称你已经在用户本机写盘、运行命令或部署（落地由宿主完成）；但要把可落地的完整内容交出来。
        - 末尾用一两句以“灵枢”口吻简报：交付了什么、有哪些合理默认假设、用户可以怎么改。
        最终只能以“灵枢”的统一口吻给用户，不要用多个 agent 分角色对话。
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
        // 先剥离推理标签（MiniMax M3 会先输出 <think>…</think> 再给 JSON），否则
        // think 内容里若出现 { 会污染 JSON 提取。
        let stripped = LingShuReasoningText.stripThinkTags(rawReply)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
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
            summary: payload.summary,
            choices: payload.choices
        )
    }
}
