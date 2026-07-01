import Foundation

/// **动态输出预算(2026-06-29 用户定调:别让大输出被截断浪费 token,按模型上下文动态上调)**。
///
/// 单次 `max_tokens` 不再写死(原 4096/16384 都是拍脑袋的常数,小了截断大文件、大了又可能超模型硬上限被网关 400)。
/// 这里按**模型上下文窗口 − 估算已用输入 − 安全余量**动态算,再夹在 `[下限, 该模型单次输出硬上限]` 之间:
///  - 输入越少 → 给的输出预算越大(尽量上调,别截断);
///  - 输入快撑满上下文 → 自动调小输出,绝不让 输入+输出 撑爆上下文;
///  - 永不超过各家**确信安全**的单次输出上限(宁可保守也不 400 砸掉整条请求)。
///
/// 纯函数、独立成模块、可单测;表是按模型名族匹配的启发式,未知模型一律走保守默认。
enum LingShuModelOutputBudget {

    /// 模型上下文窗口(token),按模型名族匹配;未知给保守默认。
    static func contextWindow(model: String) -> Int {
        let m = model.lowercased()
        if m.contains("claude")                                           { return 200_000 }
        if m.contains("gpt-5") || m.contains("gpt-4.1") || m.contains("o1") || m.contains("o3") { return 200_000 }
        if m.contains("gemini")                                           { return 1_000_000 }
        if m.contains("minimax") || m.contains("abab")                    { return 1_000_000 }   // M 系列超长上下文
        if m.contains("deepseek")                                         { return 128_000 }
        if m.contains("qwen") || m.contains("swds")                       { return 128_000 }
        if m.contains("glm")                                              { return 128_000 }
        return 64_000   // 未知:保守
    }

    /// 单次输出**硬上限**(token)——超过会被各家网关 400,只取**确信安全**的值(宁保守不砸请求)。
    static func maxOutputCap(model: String) -> Int {
        let m = model.lowercased()
        if m.contains("claude")                       { return 32_000 }   // Claude 4.x 全系确信支持 ≥32K 输出
        if m.contains("gpt-5") || m.contains("gpt-4.1") { return 32_000 }
        if m.contains("gemini")                       { return 32_000 }
        if m.contains("deepseek")                     { return 8_192 }
        if m.contains("minimax") || m.contains("abab") { return 8_192 }
        if m.contains("glm")                          { return 8_192 }
        if m.contains("qwen") || m.contains("swds")   { return 8_192 }
        return 8_192   // 未知:保守,绝不 400
    }

    /// 粗估 token 数:中英文混合按 字符数/3 估(偏大,留安全余量,宁可少给输出也别撑爆上下文)。
    static func estimateTokens(chars: Int) -> Int { max(0, chars / 3) }

    /// 这次请求该用多大 `max_tokens`:`min(输出硬上限, 上下文 − 估算输入 − 安全余量)`,夹下限 1024。
    static func dynamicMaxTokens(model: String, estimatedInputChars: Int) -> Int {
        let ctx = contextWindow(model: model)
        let cap = maxOutputCap(model: model)
        let inputTokens = estimateTokens(chars: estimatedInputChars)
        let buffer = 2_048   // 模板/不可见 token 余量,别贴边到上下文上限
        let room = ctx - inputTokens - buffer
        return max(1_024, min(cap, room))
    }
}
