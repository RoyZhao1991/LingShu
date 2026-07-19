import Foundation

/// 判断某颗脑(provider/model)是否**原生支持看图/PDF**——决定"附件直接入脑"开关能不能真生效。
/// 旧入口只保留“已知视觉模型”启发式。真正的附件入脑策略走
/// `shouldAttemptNativeMultimodal`:GPT/OpenAI 兼容通道默认先试原生多模态,失败后记住并降级。
enum LingShuMultimodal {
    private static let unsupportedDefaultsKey = "lingshu.nativeMultimodal.unsupportedModels.v1"

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

    /// GPT/OpenAI 兼容通道默认**先尝试**原生多模态；只有运行时确认该模型/端点不支持后才跳过。
    static func shouldAttemptNativeMultimodal(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        defaults: UserDefaults = LingShuRuntimeEnvironment.preferences
    ) -> Bool {
        guard !isMarkedNativeMultimodalUnsupported(
            provider: provider,
            model: model,
            endpoint: endpoint,
            protocolName: protocolName,
            defaults: defaults
        ) else { return false }

        let p = provider.lowercased()
        let m = model.lowercased()
        let e = endpoint.lowercased()
        let proto = protocolName.lowercased()

        if proto.contains("openai") || proto.contains("chat") || proto.contains("responses") {
            return true
        }
        if e.hasPrefix("http"), e.contains("/v1") {
            return true
        }
        if proto.contains("anthropic") || p.contains("anthropic") || p.contains("claude") {
            return m.contains("claude")
        }
        return isVisionCapable(provider: provider, model: model)
    }

    static func isMarkedNativeMultimodalUnsupported(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        defaults: UserDefaults = LingShuRuntimeEnvironment.preferences
    ) -> Bool {
        unsupportedKeys(defaults: defaults).contains(capabilityKey(
            provider: provider,
            model: model,
            endpoint: endpoint,
            protocolName: protocolName
        ))
    }

    static func markNativeMultimodalUnsupported(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        defaults: UserDefaults = LingShuRuntimeEnvironment.preferences
    ) {
        var keys = unsupportedKeys(defaults: defaults)
        keys.insert(capabilityKey(provider: provider, model: model, endpoint: endpoint, protocolName: protocolName))
        defaults.set(Array(keys).sorted(), forKey: unsupportedDefaultsKey)
    }

    static func clearNativeMultimodalUnsupported(
        provider: String,
        model: String,
        endpoint: String,
        protocolName: String,
        defaults: UserDefaults = LingShuRuntimeEnvironment.preferences
    ) {
        var keys = unsupportedKeys(defaults: defaults)
        keys.remove(capabilityKey(provider: provider, model: model, endpoint: endpoint, protocolName: protocolName))
        defaults.set(Array(keys).sorted(), forKey: unsupportedDefaultsKey)
    }

    private static func unsupportedKeys(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: unsupportedDefaultsKey) ?? [])
    }

    private static func capabilityKey(provider: String, model: String, endpoint: String, protocolName: String) -> String {
        [
            provider,
            model,
            endpointHost(endpoint),
            protocolName
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .joined(separator: "|")
    }

    private static func endpointHost(_ endpoint: String) -> String {
        URL(string: endpoint)?.host ?? endpoint
    }
}
