import Foundation

/// 前缀缓存（prefix cache / prompt caching）按厂商适配的**集中策略**。
///
/// 不同厂商命中前缀缓存的方式不同——把"切到哪家 → 怎么启用缓存"集中到这一个地方：
/// 换模型时由 `requestFormat`（已按 provider/protocol 推导）自动选对策略，各处无需改代码。
///  - OpenAI / DeepSeek / 通义千问 / Kimi / MiniMax 等 OpenAI 兼容 + OpenAI Responses → **服务端自动**命中，请求体零改动；
///  - Anthropic Claude → **必须在请求体里显式打 `cache_control` 断点**（system / 最后一条消息），否则完全不缓存；
///  - 其它（codex bridge / host adapter）→ 不适用。
///
/// 这是纯逻辑模块（不依赖 UI/State，可单测）。
enum LingShuPrefixCacheStrategy: String, Equatable, Sendable {
    case automatic          // 服务端自动前缀缓存，请求体零改动
    case anthropicExplicit  // 需在请求体显式打 cache_control 断点
    case unsupported        // 该通道不适用

    /// 给 UI/日志用的中文说明。
    var label: String {
        switch self {
        case .automatic: return "前缀缓存 · 自动命中"
        case .anthropicExplicit: return "前缀缓存 · 显式 cache_control"
        case .unsupported: return "前缀缓存 · 不适用"
        }
    }

    /// 给通道行副标题用的极短标签。
    var shortLabel: String {
        switch self {
        case .automatic: return "缓存·自动"
        case .anthropicExplicit: return "缓存·显式"
        case .unsupported: return "缓存·—"
        }
    }
}

enum LingShuPrefixCache {
    /// 按请求格式决定缓存策略——格式由 provider/protocol/endpoint 推导，所以换模型自动选对。
    static func strategy(for format: LingShuModelGatewayRequestFormat) -> LingShuPrefixCacheStrategy {
        switch format {
        case .anthropicMessages: return .anthropicExplicit
        case .responses, .chatCompletions: return .automatic
        case .hostAdapter: return .unsupported
        }
    }

    /// Anthropic 缓存断点标记（ephemeral：5 分钟 TTL 的临时前缀缓存）。
    static var anthropicCacheControl: [String: Any] { ["type": "ephemeral"] }

    /// 把纯文本包成带 cache_control 的 Anthropic content block（供 system / 最后一条消息打断点）。
    static func anthropicCachedTextBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text, "cache_control": anthropicCacheControl]
    }

    /// 从响应 `usage` 解析前缀缓存命中量（跨厂商口径统一，谁有读谁的）：
    ///  - OpenAI / 兼容：`usage.prompt_tokens_details.cached_tokens`
    ///  - DeepSeek：`usage.prompt_cache_hit_tokens`
    ///  - Anthropic：`usage.cache_read_input_tokens`
    /// 返回（输入总 token, 命中缓存的 token）。命中越高越省钱。
    static func parseCacheUsage(_ usage: [String: Any]) -> (promptTokens: Int?, cachedTokens: Int?) {
        var cached: Int?
        if let details = usage["prompt_tokens_details"] as? [String: Any], let c = details["cached_tokens"] as? Int {
            cached = c
        } else if let c = usage["prompt_cache_hit_tokens"] as? Int {
            cached = c
        } else if let c = usage["cache_read_input_tokens"] as? Int {
            cached = c
        }
        if let prompt = usage["prompt_tokens"] as? Int {
            return (prompt, cached)
        }
        if let input = usage["input_tokens"] as? Int {
            let read = usage["cache_read_input_tokens"] as? Int ?? 0
            let creation = usage["cache_creation_input_tokens"] as? Int ?? 0
            // Anthropic 的 input_tokens 不含缓存读/写; UI 命中率要用同一分母,否则会算出 >100%。
            return (input + read + creation, cached)
        }
        return (nil, cached)
    }
}
