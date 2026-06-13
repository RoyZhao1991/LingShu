import Foundation

@MainActor
extension LingShuState {
    /// 主线程默认上下文预算（字符）。MiniMax-M2.7 等网关模型 max-model-len 约 32k token，
    /// 中文约 1.5 字符/token，这里给历史留约 1.6 万字符，其余留给系统提示、记忆与回复。
    ///
    /// 注意：网关是无状态 chat/completions，模型本身不跨请求记忆——必须每轮把会话发过去；
    /// 性能靠 vLLM 的 prefix caching（前缀稳定即命中 KV 缓存，不重算）。因此这里保持
    /// append-only 的干净轮次（稳定的 system + 顺序一致的 user/assistant），让缓存最大命中，
    /// 而不是每轮重排或塞进会变化的记忆快照。
    static let conversationContextBudget = 16000

    /// 构造发送给模型的会话上下文：系统人格之外的真实 user/assistant 轮次，按字符预算取最近窗口。
    /// finalUserPrompt 为本轮真正要问的内容（可能是路由包装后的提示）；excludingCurrentRawPrompt
    /// 用于剔除历史里与本轮重复的末条用户消息，避免重复注入。
    func modelConversationMessages(
        finalUserPrompt: String,
        excludingCurrentRawPrompt rawPrompt: String,
        budget: Int = LingShuState.conversationContextBudget
    ) -> [LingShuModelMessage] {
        var history = recentConversationTurns(
            budget: budget,
            excludingTrailingPromptMatching: rawPrompt,
            persistedDigest: persistedConversationDigest
        )
        history.append(.init(role: "user", content: finalUserPrompt))
        return history
    }

    /// 供后台路由/执行复用：构造与前台一致的会话上下文。后台段会带上完成它所需的历史，
    /// 不再以空上下文执行。
    func backgroundConversationMessages(excludingTrailingPromptMatching rawPrompt: String) -> [LingShuModelMessage] {
        recentConversationTurns(
            budget: LingShuState.conversationContextBudget,
            excludingTrailingPromptMatching: rawPrompt,
            persistedDigest: persistedConversationDigest
        )
    }

    /// 纯函数版上下文窗口构造，便于离线测试。预算内全量保留原文；
    /// 超预算时不再直接丢弃旧轮次，而是交给压缩引擎折叠成滚动摘要随上下文注入，
    /// 折叠边界按块推进以保持前缀稳定（利好 vLLM prefix caching）。
    nonisolated static func conversationWindow(
        from messages: [ChatMessage],
        budget: Int,
        excludingTrailingPromptMatching rawPrompt: String?,
        persistedDigest: String = "",
        normalize: (String) -> String,
        compact: (String) -> String
    ) -> [LingShuModelMessage] {
        let composition = LingShuContextCompressionEngine.compose(
            messages: messages,
            budget: budget,
            baseDigest: persistedDigest,
            excludingTrailingPromptMatching: rawPrompt,
            normalize: normalize,
            compact: compact
        )
        return LingShuContextCompressionEngine.digestMessages(from: composition.digest) + composition.verbatim
    }

    private func recentConversationTurns(
        budget: Int,
        excludingTrailingPromptMatching rawPrompt: String,
        persistedDigest: String
    ) -> [LingShuModelMessage] {
        LingShuState.conversationWindow(
            from: chatMessages,
            budget: budget,
            excludingTrailingPromptMatching: rawPrompt,
            persistedDigest: persistedDigest,
            normalize: { self.normalizeMemoryText($0) },
            compact: { LingShuState.compactForModelContext($0) }
        )
    }

    /// 单条上限放宽到 4000 字符：只截断超长贴文，正常多轮对话完整保留。
    nonisolated static func compactForModelContext(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 4000 else { return cleaned }
        return String(cleaned.prefix(4000)) + "…（节选）"
    }
}
