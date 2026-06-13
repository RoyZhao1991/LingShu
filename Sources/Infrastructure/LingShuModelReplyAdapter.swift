import Foundation

/// 模型回复适配器：不同模型把"思考过程"放在不同位置——
/// MiniMax M3 内联 `<think>…</think>`，DeepSeek-R1 用独立 reasoning_content 字段，
/// OpenAI o 系列不返回，标准模型没有。把"原始回复 → 干净正文"的差异收敛到适配器，
/// 避免把模型方言散落进路由、执行和展示逻辑。
protocol LingShuModelReplyAdapting: Sendable {
    /// 取出用户可见的干净正文（剥离思考标签等模型特定包装）。
    func normalizedReplyText(_ raw: String) -> String
    /// 为一次流式请求创建有状态解析器：把原始增量流拆成（思考增量, 正文增量）。
    /// 每次请求必须新建实例——解析器内部带跨 chunk 的标签缓冲状态。
    func makeStreamParser() -> LingShuReplyStreamParsing
}

/// 一段流式增量经适配器归一化后的事件。
struct LingShuReplyStreamEvent: Equatable, Sendable {
    var reasoningDelta: String = ""
    var contentDelta: String = ""

    var isEmpty: Bool { reasoningDelta.isEmpty && contentDelta.isEmpty }
}

/// 有状态的流式解析器：吞入原始增量，吐出归一化事件；流结束时 finish() 排空缓冲。
protocol LingShuReplyStreamParsing: AnyObject {
    func ingest(_ rawDelta: String) -> LingShuReplyStreamEvent
    func finish() -> LingShuReplyStreamEvent
}

/// 内联 `<think>…</think>` 思考标签的模型（MiniMax M3、Qwen、DeepSeek 蒸馏版等）。
struct LingShuInlineThinkReplyAdapter: LingShuModelReplyAdapting {
    func normalizedReplyText(_ raw: String) -> String {
        LingShuReasoningText.stripThinkTags(raw)
    }

    func makeStreamParser() -> LingShuReplyStreamParsing {
        LingShuInlineThinkStreamParser()
    }
}

/// 思考已由 API 分离或本就没有思考标签的模型（标准 OpenAI 兼容）。
struct LingShuPlainReplyAdapter: LingShuModelReplyAdapting {
    func normalizedReplyText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func makeStreamParser() -> LingShuReplyStreamParsing {
        LingShuPassthroughStreamParser()
    }
}

/// 按当前主通道的 provider/model 选择回复适配器。新增模型族只需在此登记，
/// 不必改动路由/执行/展示代码。
enum LingShuModelReplyAdapters {
    static func adapter(provider: String, model: String) -> LingShuModelReplyAdapting {
        let signature = "\(provider) \(model)".lowercased()
        let inlineThinkFamilies = ["minimax", "m3", "m2.7", "qwen", "deepseek", "glm", "kimi"]
        if inlineThinkFamilies.contains(where: { signature.contains($0) }) {
            return LingShuInlineThinkReplyAdapter()
        }
        return LingShuPlainReplyAdapter()
    }
}

/// 直通解析器：没有思考标签的流，全部增量都是正文。
final class LingShuPassthroughStreamParser: LingShuReplyStreamParsing {
    func ingest(_ rawDelta: String) -> LingShuReplyStreamEvent {
        .init(contentDelta: rawDelta)
    }

    func finish() -> LingShuReplyStreamEvent {
        .init()
    }
}

/// 内联 `<think>…</think>` 的流式状态机。标签可能被任意切碎在多个 chunk 里
/// （比如 "<th" + "ink>"），所以末尾可能构成标签前缀的字符先留在缓冲里，
/// 等下一个 chunk 进来再判定。
final class LingShuInlineThinkStreamParser: LingShuReplyStreamParsing {
    // 覆盖多种命名空间/变体：<think> / <mm:think> / <thinking>。新增变体只要往这两个表里加。
    private static let openTags = ["<think>", "<mm:think>", "<thinking>"]
    private static let closeTags = ["</think>", "</mm:think>", "</thinking>"]

    private var buffer = ""
    private var inThink = false
    private var currentTags: [String] { inThink ? Self.closeTags : Self.openTags }

    func ingest(_ rawDelta: String) -> LingShuReplyStreamEvent {
        buffer += rawDelta
        var event = LingShuReplyStreamEvent()

        while true {
            if let match = earliestRange(of: currentTags, in: buffer) {
                let emitted = String(buffer[buffer.startIndex..<match.lowerBound])
                appendEmission(emitted, to: &event)
                buffer.removeSubrange(buffer.startIndex..<match.upperBound)
                inThink.toggle()
            } else {
                let keep = maxPendingTagPrefixLength(in: buffer, tags: currentTags)
                let emitCount = buffer.count - keep
                if emitCount > 0 {
                    appendEmission(String(buffer.prefix(emitCount)), to: &event)
                    buffer.removeFirst(emitCount)
                }
                break
            }
        }
        return event
    }

    func finish() -> LingShuReplyStreamEvent {
        var event = LingShuReplyStreamEvent()
        // 流结束后缓冲里只可能剩下不完整的标签前缀；残缺标签不是用户内容，直接丢弃，
        // 其余文本按当前所在通道吐出。
        let keep = maxPendingTagPrefixLength(in: buffer, tags: currentTags)
        let emit = String(buffer.prefix(buffer.count - keep))
        appendEmission(emit, to: &event)
        buffer = ""
        inThink = false
        return event
    }

    private func appendEmission(_ text: String, to event: inout LingShuReplyStreamEvent) {
        guard !text.isEmpty else { return }
        if inThink {
            event.reasoningDelta += text
        } else {
            event.contentDelta += text
        }
    }

    /// 缓冲里**最靠前**的任一标签变体出现位置。
    private func earliestRange(of tags: [String], in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for tag in tags {
            if let r = text.range(of: tag, options: .caseInsensitive),
               best == nil || r.lowerBound < best!.lowerBound {
                best = r
            }
        }
        return best
    }

    /// 缓冲末尾可能正在"长出"某个标签的最长前缀（取所有变体里最长的那个，避免吐出半截标签）。
    private func maxPendingTagPrefixLength(in text: String, tags: [String]) -> Int {
        tags.map { pendingTagPrefixLength(in: text, tag: $0) }.max() ?? 0
    }

    private func pendingTagPrefixLength(in text: String, tag: String) -> Int {
        let maxKeep = min(tag.count - 1, text.count)
        guard maxKeep > 0 else { return 0 }
        for length in stride(from: maxKeep, through: 1, by: -1) {
            if String(text.suffix(length)).lowercased() == String(tag.prefix(length)).lowercased() {
                return length
            }
        }
        return 0
    }
}
