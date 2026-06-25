import Foundation

/// 完全版 #1·**模型通道续接策略**(纯逻辑、可测)。
///
/// 灵枢是本地中枢,管的是"外部大脑通道"(OpenAI/Claude/DeepSeek/Kimi/私有)的上下文续接——不是把灵枢远端化。
/// 不同通道续接机制不同:OpenAI Responses(previous_response_id)= **服务端原生续接**;
/// DeepSeek/Kimi/Claude messages = **无状态 + 前缀缓存**(续接=保持前缀稳定);其余 = **本地压缩上下文**。
///
/// **关键(避开 #1 的设计陷阱):本回合若改写了上下文(压缩/纠正/注入工具结果),必须降级到 prefixStable**——
/// 服务端原生续接持有历史链,与"客户端改写历史"冲突;改写了就别用服务端链,回退重发(靠前缀缓存)。
enum LingShuContinuationMode: String, Sendable, Equatable {
    case native          // 服务端原生续接(传 previous_response_id / resume id)
    case prefixStable    // 无状态重发,靠前缀缓存(保持前缀稳定)
    case localCompressed // 本地维护压缩上下文(不支持前缀缓存的弱通道)
}

enum LingShuModelChannelStrategy {
    /// 该 provider 是否支持服务端原生续接。
    static func supportsNativeContinuation(provider: String) -> Bool {
        let p = provider.lowercased()
        return p.contains("responses")
    }

    /// 本通道是否走前缀缓存(无状态 chat-completions 系)。
    static func supportsPrefixCache(provider: String) -> Bool {
        let p = provider.lowercased()
        return p.contains("openai") || p.contains("anthropic") || p.contains("claude")
            || p.contains("deepseek") || p.contains("kimi") || p.contains("moonshot")
            || p.contains("doubao") || p.contains("qwen")
    }

    /// 决定本回合续接模式。`didRewriteContext`=本回合压缩/纠正/改写过历史(则禁用服务端续接)。
    static func mode(provider: String, didRewriteContext: Bool) -> LingShuContinuationMode {
        if !didRewriteContext, supportsNativeContinuation(provider: provider) { return .native }
        if supportsPrefixCache(provider: provider) { return .prefixStable }
        return .localCompressed
    }
}

extension LingShuModelChannelStrategy {
    /// 会话签名(用于判"本回合是否只是干净追加、没改写早段历史")。进程内稳定即可。
    static func signature(_ messages: [LingShuAgentMessage]) -> [String] {
        messages.map { "\($0.role.rawValue)#\($0.content.hashValue)#\($0.toolCalls.count)" }
    }
    /// current 是否是 previous 的"干净追加"(previous 为 current 前缀)=没改写早段。
    /// 压缩(早段换成摘要)/纠正(早段插消息)都会让前缀不等 → 非干净追加 → 该降级到 prefixStable。
    static func isCleanContinuation(previous: [String], current: [String]) -> Bool {
        guard !previous.isEmpty, current.count >= previous.count else { return false }
        return Array(current.prefix(previous.count)) == previous
    }
    /// 本回合该带的续接 token:native 且有上轮响应 id → 带;否则 nil(prefixStable/无 id)。
    static func continuationToken(mode: LingShuContinuationMode, lastResponseId: String?) -> String? {
        mode == .native ? lastResponseId : nil
    }
}
