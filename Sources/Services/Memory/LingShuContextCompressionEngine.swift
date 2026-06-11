import Foundation

/// 上下文压缩引擎：把完整对话历史折叠进模型上下文预算——
/// 最近轮次保留原文，更早的轮次压缩成「滚动摘要」随上下文一起注入，
/// 旧对话不再被直接丢弃。
///
/// 与 vLLM prefix caching 的配合：折叠边界按块（blockSize 条消息）推进，
/// 边界不动时摘要逐字不变、保留区 append-only，缓存照常命中；
/// 只有新一块历史跨入折叠区时摘要才变化一次。
enum LingShuContextCompressionEngine {
    struct Composition: Equatable {
        /// 被折叠的更早轮次的滚动摘要；空串表示全部历史都在预算内、没有折叠。
        var digest: String
        /// 预算内保留原文的最近轮次（正序）。
        var verbatim: [LingShuModelMessage]
        var foldedTurnCount: Int
    }

    /// 折叠边界推进的步长（消息条数）。块越大摘要越稳定（利好前缀缓存），
    /// 但单次折叠的信息损失越集中。
    static let foldBlockSize = 8

    static func compose(
        messages: [ChatMessage],
        budget: Int,
        digestBudget: Int = 1200,
        excludingTrailingPromptMatching rawPrompt: String?,
        normalize: (String) -> String,
        compact: (String) -> String
    ) -> Composition {
        var visible = messages.filter { !$0.isLoading && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let rawPrompt,
           let last = visible.last,
           last.isUser,
           normalize(last.text) == normalize(rawPrompt) {
            visible.removeLast()
        }
        guard !visible.isEmpty else {
            return .init(digest: "", verbatim: [], foldedTurnCount: 0)
        }

        let compacted = visible.map { message in
            (isUser: message.isUser, content: compact(message.text))
        }
        let costs = compacted.map { $0.content.isEmpty ? 0 : $0.content.count + 8 }

        // 找到最小的按块对齐折叠边界，使保留区的开销不超过预算。
        var foldBoundary = 0
        var verbatimCost = costs.reduce(0, +)
        while verbatimCost > budget && foldBoundary < compacted.count {
            let nextBoundary = min(foldBoundary + foldBlockSize, compacted.count)
            for index in foldBoundary..<nextBoundary {
                verbatimCost -= costs[index]
            }
            foldBoundary = nextBoundary
        }

        // 预算极小时即使全折叠也放不下：保底保留最后一条。
        if foldBoundary >= compacted.count {
            foldBoundary = compacted.count - 1
        }

        let verbatim = compacted[foldBoundary...]
            .filter { !$0.content.isEmpty }
            .map { LingShuModelMessage(role: $0.isUser ? "user" : "assistant", content: $0.content) }
        let digest = foldBoundary > 0
            ? digestText(for: Array(compacted[..<foldBoundary]), limit: digestBudget)
            : ""

        return .init(digest: digest, verbatim: Array(verbatim), foldedTurnCount: foldBoundary)
    }

    /// 把折叠区的轮次抽取成确定性的摘要文本：每轮压成一行（用户取头、回复取头尾），
    /// 超限时整体再过一次首尾压缩。不依赖模型调用，离线可测。
    static func digestText(for turns: [(isUser: Bool, content: String)], limit: Int) -> String {
        let lines = turns.compactMap { turn -> String? in
            let flattened = turn.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !flattened.isEmpty else { return nil }
            if turn.isUser {
                return "你：\(clip(flattened, head: 64))"
            }
            return "灵枢：\(clip(flattened, head: 56, tail: 32))"
        }
        guard !lines.isEmpty else { return "" }
        return LingShuMemoryTextToolkit.compactSummary(lines.joined(separator: "\n"), limit: limit)
    }

    /// 注入到会话最前面的压缩记忆消息对：以 user 角色注入（system 角色会
    /// 顶掉网关的主系统提示），补一条 assistant 确认以保持角色交替合法。
    static func digestMessages(from digest: String) -> [LingShuModelMessage] {
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [
            .init(role: "user", content: "【背景】以下是我们更早对话的压缩记忆，供你延续上下文，不需要逐条回应：\n\(trimmed)"),
            .init(role: "assistant", content: "好的，我已经衔接上更早的对话背景。")
        ]
    }

    private static func clip(_ text: String, head: Int, tail: Int = 0) -> String {
        guard text.count > head + tail + 2 else { return text }
        if tail > 0 {
            return "\(text.prefix(head))…\(text.suffix(tail))"
        }
        return "\(text.prefix(head))…"
    }
}
