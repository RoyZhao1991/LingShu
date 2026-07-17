import SwiftUI

/// P5 统一「扩展」面板:一个列表管理 skills + MCP——启停 / 版本 / 权限作用域 / 风险 / 效能(成功率)。
/// 停用的扩展不再被匹配/调用(经 `syncExtensionEnablement` 真生效)。
struct LingShuExtensionsPanel: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var connectors: LingShuConnectorRegistry
    @ObservedObject private var registry = LingShuExtensionRegistry.shared

    init(state: LingShuState) {
        _state = ObservedObject(wrappedValue: state)
        _connectors = ObservedObject(wrappedValue: state.connectorRegistry)
    }

    private var extensions: [LingShuExtension] {
        registry.extensions(skills: LingShuSkillLoader.loadSkills(), mcp: connectors.servers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.loc("扩展(技能 + 连接器统一管理)", "Extensions (Skills + Connectors)")).font(.headline)
            Text(state.loc("声明式权限作用域 + 启停 + 效能。停用的扩展不再被匹配/调用;低成功率的会被建议降级。", "Manage permission scopes, enablement, and effectiveness. Disabled extensions are not matched or invoked; low-performing ones are flagged for demotion."))
                .font(.caption).foregroundStyle(.secondary)

            let exts = extensions
            if exts.isEmpty {
                Text(state.loc("还没有可管理的扩展(用户技能 / MCP 连接器)。", "No manageable extensions yet (user skills or MCP connectors)."))
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            } else {
                ForEach(exts) { ext in row(ext) }
            }
        }
    }

    @ViewBuilder private func row(_ ext: LingShuExtension) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ext.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(ext.kind.displayName(language: state.language)).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if ext.kind == .skill { Text("v\(ext.version)").font(.caption2).foregroundStyle(.secondary) }
                    if ext.riskLevel != "—" {
                        Text(state.loc("风险 \(ext.riskLevel)", "Risk \(ext.riskLevel)")).font(.caption2)
                            .foregroundStyle(ext.riskLevel == "high" ? .red : (ext.riskLevel == "medium" ? .orange : .secondary))
                    }
                    if registry.shouldDemote(ext.id) {
                        Text(state.loc("建议降级", "Demotion Suggested")).font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(ext.localizedPermissionSummary(language: state.language)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if let rate = ext.successRate {
                    Text(state.loc("成功率 \(Int(rate * 100))%(\(ext.successCount)/\(ext.successCount + ext.failCount))", "Success \(Int(rate * 100))% (\(ext.successCount)/\(ext.successCount + ext.failCount))"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { ext.enabled }, set: { toggle(ext, $0) })).labelsHidden()
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggle(_ ext: LingShuExtension, _ on: Bool) {
        switch ext.kind {
        case .skill, .plugin:
            registry.setEnabled(ext.id, on)
            state.syncExtensionEnablement()   // 真生效:停用即不再匹配/应用
        case .mcp:
            connectors.setEnabled(id: ext.id, enabled: on)
        }
    }
}
