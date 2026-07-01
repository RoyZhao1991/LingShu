import Foundation

/// 判断某颗脑(provider/model)是否**原生支持看图/PDF**——决定"附件直接入脑"开关能不能真生效。
/// 启发式按模型名匹配(会随新模型更新);不认识的当**不支持**(保守:宁可回退 VL,也不把图发给纯文本脑触发报错)。纯函数可单测。
enum LingShuMultimodal {
    static func isVisionCapable(provider: String, model: String) -> Bool {
        let m = model.lowercased()
        let p = provider.lowercased()
        if p.contains("anthropic") || p.contains("claude") { return m.contains("claude") }        // claude-3 起全多模态
        if m.contains("gpt-4o") || m.contains("gpt-4.1") || m.contains("gpt-5") || m.contains("chatgpt-4o") { return true }
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") { return true }
        if m.contains("gemini") { return true }
        if m.contains("-vl") || m.contains("vision") || m.contains("4v") || m.contains("qwen2.5-vl") { return true }
        if m.contains("grok-4") || m.contains("grok-vision") || m.contains("pixtral") || m.contains("llama-4") { return true }
        return false
    }
}
