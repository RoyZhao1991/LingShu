import Foundation

@MainActor
extension LingShuState {
    /// 显式接入本机 Codex Computer Use。
    ///
    /// 这是用户触发的注册动作，不做启动期静默扫描：先从 Codex 的权威插件清单确认
    /// `computer-use` 已安装且启用，再探活 Codex，最后才写入灵枢的外部 Agent 插件库。
    func connectCodexComputerUse() async -> String {
        let preset = LingShuAgentIntegrationPresetCatalog.codexComputerUse
        guard let executable = LingShuAgentIntegrationPresetCatalog.resolveExecutable(for: preset) else {
            return "未找到本机 Codex。请先安装或恢复 ChatGPT/Codex，再重试接入。"
        }

        let candidate = preset.makePlugin(executable: executable)
        let capabilities = await Task.detached(priority: .userInitiated) {
            LingShuAgentCapabilityDiscovery.discover(candidate)
        }.value
        guard let computerUse = preset.requiredCapability(in: capabilities) else {
            return "已找到 Codex，但它的官方 Computer Use 插件未安装或未启用。请先在 Codex 中启用 computer-use，再重试。"
        }

        let workingDirectory = agentWorkingDirectory
        let probe = await LingShuAgentPluginStore.probeAvailability(candidate, workingDirectory: workingDirectory)
        var registered = candidate
        registered.available = probe.ok
        registered.unavailableReason = probe.ok ? nil : probe.reason
        registered.lastCheckedAt = Date()
        guard LingShuAgentPluginStore.register(registered) else {
            return "Codex Computer Use 已通过发现，但写入灵枢插件库失败。"
        }

        discoveredAgentCapabilities.removeAll { $0.agentID == registered.id }
        discoveredAgentCapabilities.append(contentsOf: capabilities)
        agentCapabilitiesRefreshedAt = Date()
        invalidateInvocablePluginCatalog()
        appendTrace(
            kind: probe.ok ? .system : .warning,
            actor: "agent插件",
            title: probe.ok ? "Codex Computer Use 已接入" : "Codex 已登记但不可用",
            detail: probe.ok
                ? "已从 Codex 权威插件清单确认 \(computerUse.id)，可通过 @Codex·\(computerUse.name) 调用。"
                : probe.reason
        )

        guard probe.ok else {
            return "Computer Use 已确认存在，但 Codex 当前不可用：\(probe.reason)。恢复 Codex 登录或额度后点“重新检测”。"
        }
        return "已接入 Codex Computer Use。现在可以用 @Codex·\(computerUse.name) 指定它操作 Mac App，大脑也能在需要时自动调度。"
    }

    func isCodexComputerUseConnected() -> Bool {
        let preset = LingShuAgentIntegrationPresetCatalog.codexComputerUse
        guard LingShuAgentPluginStore.plugin(id: preset.id)?.isCallableNow == true else { return false }
        return preset.requiredCapability(in: discoveredAgentCapabilities) != nil
    }
}
