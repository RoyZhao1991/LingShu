import Foundation

/// 模型回复适配器：不同模型把"思考过程"放在不同位置——
/// MiniMax M3 内联 `<think>…</think>`，DeepSeek-R1 用独立 reasoning_content 字段，
/// OpenAI o 系列不返回，标准模型没有。把"原始回复 → 干净正文"的差异收敛到适配器，
/// 避免把模型方言散落进路由、执行和展示逻辑。
protocol LingShuModelReplyAdapting: Sendable {
    /// 取出用户可见的干净正文（剥离思考标签等模型特定包装）。
    func normalizedReplyText(_ raw: String) -> String
}

/// 内联 `<think>…</think>` 思考标签的模型（MiniMax M3、Qwen、DeepSeek 蒸馏版等）。
struct LingShuInlineThinkReplyAdapter: LingShuModelReplyAdapting {
    func normalizedReplyText(_ raw: String) -> String {
        LingShuReasoningText.stripThinkTags(raw)
    }
}

/// 思考已由 API 分离或本就没有思考标签的模型（标准 OpenAI 兼容）。
struct LingShuPlainReplyAdapter: LingShuModelReplyAdapting {
    func normalizedReplyText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
