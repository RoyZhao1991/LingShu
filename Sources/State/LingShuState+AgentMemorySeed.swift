import Foundation

/// 主会话**跨会话记忆 seed**子域(从 LingShuState+AgentBackbone.swift 拆出,保后者聚焦"骨干接线"+守 500 行架构闸)。
/// 记忆归一:跨会话只喂【蒸馏摘要】、不原样回放历史助手输出(断"旧错误自述被模仿"的 seed 污染);会话内当轮仍走 verbatim 上下文。
@MainActor
extension LingShuState {

    /// 记忆归一:跨会话只喂【蒸馏摘要】、不原样回放历史助手输出(断"旧错误自述被模仿"的 seed 污染);会话内当轮仍走 verbatim 上下文。
    func seededDistilledMemory() async -> [LingShuAgentMessage] {
        var seed: [LingShuAgentMessage] = []
        // 跨 app 重启:确保最近产出物从增量存储恢复到内存,主会话首轮即知悉(让重启后"运行起来"也接得上)。
        if recentDeliverables.isEmpty {
            let restored = await deliverableStore.all()
            if recentDeliverables.isEmpty { recentDeliverables = Array(restored.suffix(8)) }
        }
        let distilled = await distillConversationMemory()
        if !distilled.isEmpty {
            seed.append(.init(role: .system, content: "【跨会话记忆(已蒸馏,供延续上下文,不要逐条复述、不要照搬其中措辞)】\n\(distilled)"))
        }
        // 最近产出物上下文:主会话也知悉,"运行起来/继续"留主线程时同样接得上(跨重启从增量存储恢复)。
        let deliverCtx = recentDeliverablesContext()
        if !deliverCtx.isEmpty { seed.append(.init(role: .system, content: deliverCtx)) }
        seed.append(identityAnchorMessage())
        return seed
    }

    /// 身份锚点(最近性最强),压过任何历史里"由 MiniMax 开发"的旧错误自述。
    func identityAnchorMessage() -> LingShuAgentMessage {
        .init(role: .system, content: "身份提醒(最高优先级):你是灵枢,由 Roy Zhao 开发。你是**贾维斯式的通用私人助理**,不是编程工具——**遇到含糊、没给明确任务的输入,按通才接住**(出谋划策/查证研究/规划/操作设备/打理生活与工作),主动问清要达成什么或给个方向,**绝不缩回「你想让我写什么代码」**。**不提底层用什么模型**(可替换、与身份无关)。被问身份只答:'我是灵枢,由 Roy Zhao 打造。'")
    }

    /// 用模型把近期对话(含旧压缩摘要)蒸馏成简洁要点记忆——提炼而非复述,断开污染。
    func distillConversationMemory() async -> String {
        var lines: [String] = []
        let digest = persistedConversationDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !digest.isEmpty { lines.append("更早摘要:\(digest.prefix(600))") }
        let recent = chatMessages
            .filter { !$0.isLoading && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(24)
        for message in recent {
            lines.append("\(message.isUser ? "用户" : "灵枢"):\(message.text.prefix(400))")
        }
        guard !lines.isEmpty else { return "" }
        let prompt = """
        把下面对话压成简洁"记忆"供后续会话延续(提炼要点、不要原样复述,150 字内):
        - 用户是谁 / 偏好 / 明确要求
        - 已完成的事(含产出物文件路径)
        - 未决 / 待办项
        - 已澄清的关键结论(如身份口径等)
        对话:
        \(lines.joined(separator: "\n"))
        """
        let summarizer = LingShuAgentSession(
            id: "distill-\(UUID().uuidString.prefix(6))",
            system: "你是记忆蒸馏器,只输出提炼后的要点摘要,不寒暄、不复述原文。",
            tools: [],
            model: makeAgentModelAdapter(),
            maxTurns: 1
        )
        let result = await summarizer.send(prompt)
        if case .completed(let text) = result {
            return LingShuReasoningText.stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
