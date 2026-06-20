import Foundation

/// 大模型配置「加密导出 / 一键导入」接线(把当前接入的脑/通道/密钥打成口令加密文件,换机/给别人一键导入即用)。
/// 纯加解密在 `LingShuModelConfigPortability`(可单测);这里只做**采集当前配置 + 落盘 + 导入后应用使其立即可用**。
@MainActor
extension LingShuState {

    /// 采集当前**完整**模型配置(当前脑选型 + 各通道 名/端点/模型 + 全部密钥)。
    func currentModelConfigBundle() -> LingShuModelConfigBundle {
        LingShuModelConfigBundle(
            provider: modelProvider,
            model: modelName,
            endpoint: endpoint,
            channels: channelConfigs,
            credentials: credentialStore.allCredentials(),
            note: "灵枢模型配置导出"
        )
    }

    /// 导出加密配置文件(口令加密,可换机/分享)。成功返回(打包的密钥条数, 脱敏摘要)。
    func exportModelConfig(passphrase: String, to url: URL) -> Result<(credentialCount: Int, summary: String), Error> {
        let bundle = currentModelConfigBundle()
        do {
            let data = try LingShuModelConfigPortability.export(bundle, passphrase: passphrase)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            appendTrace(kind: .result, actor: "配置", title: "已加密导出", detail: "\(bundle.redactedSummary) → \(url.lastPathComponent)")
            return .success((bundle.credentials.count, bundle.redactedSummary))
        } catch {
            appendTrace(kind: .warning, actor: "配置", title: "导出失败", detail: error.localizedDescription)
            return .failure(error)
        }
    }

    /// 一键导入加密配置文件(口令解密 → 恢复脑/通道/密钥 → 重建会话使其**立即可用**)。
    func importModelConfig(passphrase: String, from url: URL) -> Result<LingShuModelConfigBundle, Error> {
        do {
            let raw = try Data(contentsOf: url)
            let bundle = try LingShuModelConfigPortability.importBundle(raw, passphrase: passphrase)
            applyImportedModelConfig(bundle)
            appendTrace(kind: .result, actor: "配置", title: "已导入并启用", detail: bundle.redactedSummary)
            return .success(bundle)
        } catch {
            appendTrace(kind: .warning, actor: "配置", title: "导入失败", detail: (error as? LingShuModelConfigPortability.PortError)?.errorDescription ?? error.localizedDescription)
            return .failure(error)
        }
    }

    /// 应用导入的配置:恢复全部密钥(本机加密落盘)+ 各通道配置 + 当前脑选型,并重建常驻会话让新脑立即生效。
    func applyImportedModelConfig(_ bundle: LingShuModelConfigBundle) {
        credentialStore.bulkSet(bundle.credentials)              // 密钥恢复(导入即转成本机绑定加密态)
        channelConfigs = bundle.channels                         // 各通道 名/端点/模型(didSet 持久化)
        // 当前脑选型(didSet 持久化到 UserDefaults / credentialStore)
        modelProvider = bundle.provider
        endpoint = bundle.endpoint
        modelName = bundle.model
        // 刷新当前激活密钥:优先按 preset.id 取,回退按 provider 名取(覆盖不同命名习惯)。
        if let preset = selectedModelPreset, let k = credentialStore.apiKey(forProvider: preset.id), !k.isEmpty {
            apiKey = k
        } else if let k = credentialStore.apiKey(forProvider: bundle.provider), !k.isEmpty {
            apiKey = k
        }
        resetBrainScoreForCurrentBrain()   // 导入新配置=可能换脑 → 评分归零
        // 换脑即时生效:清掉常驻会话(主/自主),下一回合用新脑重建 adapter。
        mainAgentSessionHolder = nil
        autonomousSessionHolder = nil
    }

    // MARK: - MCP 控制口子(供脚本化导入导出 E2E;UI 走上面的 export/importModelConfig)

    func controlExportModelConfig(passphrase: String?, path: String?) -> (text: String, isError: Bool) {
        guard let pass = passphrase, !pass.isEmpty, let path, !path.isEmpty else { return ("缺少参数 passphrase / path", true) }
        switch exportModelConfig(passphrase: pass, to: URL(fileURLWithPath: path)) {
        case .success(let r): return (Self.controlJSON(["ok": true, "path": path, "credentialCount": r.credentialCount, "summary": r.summary]), false)
        case .failure(let e): return (Self.controlJSON(["ok": false, "error": Self.portErr(e)]), false)
        }
    }

    func controlImportModelConfig(passphrase: String?, path: String?) -> (text: String, isError: Bool) {
        guard let pass = passphrase, !pass.isEmpty, let path, !path.isEmpty else { return ("缺少参数 passphrase / path", true) }
        switch importModelConfig(passphrase: pass, from: URL(fileURLWithPath: path)) {
        case .success(let b): return (Self.controlJSON(["ok": true, "provider": b.provider, "model": b.model, "endpoint": b.endpoint, "channelCount": b.channels.count, "credentialCount": b.credentials.count, "keyActive": !apiKey.isEmpty]), false)
        case .failure(let e): return (Self.controlJSON(["ok": false, "error": Self.portErr(e)]), false)
        }
    }

    private static func portErr(_ e: Error) -> String {
        (e as? LingShuModelConfigPortability.PortError)?.errorDescription ?? e.localizedDescription
    }
    private static func controlJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
