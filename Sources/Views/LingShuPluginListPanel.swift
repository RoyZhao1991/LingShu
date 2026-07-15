import SwiftUI

/// **插件列表**(配置 > 插件):展示当前真正可调用的入口;外部 agent 跟随自检健康状态动态出现/隐藏。
struct LingShuPluginListPanel: View {
    @ObservedObject var state: LingShuState
    @State private var isConnectingComputerUse = false
    @State private var computerUseMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "square.grid.2x2", title: "插件列表",
                          subtitle: "可调用入口跟随自检结果动态刷新:agent 不可用时不会出现在这里或输入框「+」菜单。")

            codexComputerUseCard

            let all = state.invocablePlugins()
            let agents = all.filter { $0.kind == .agent }
            let caps = all.filter { $0.kind == .agentCapability }
            if !agents.isEmpty {
                groupTitle("外部 agent", "自检探活通过后才允许 @ 调用")
                ForEach(agents) { p in
                    row(name: p.displayName, badge: "agent", badgeColor: .cyan, detail: p.subtitle, available: true,
                        rechecking: false, onRecheck: nil, onRemove: nil)
                }
            }
            if !caps.isEmpty {
                groupTitle("外部 agent 技能", "仅展示可用 agent 已启用、已安装的子能力")
                ForEach(caps) { p in
                    row(name: p.displayName, badge: "skill", badgeColor: .mint, detail: p.subtitle, available: true,
                        rechecking: false, onRecheck: nil, onRemove: nil)
                }
            }
            // ── 内置插件 / 技能
            groupTitle("内置插件", "输入框点「+」或打 @名字 即可调用")
            ForEach(all.filter { $0.kind == .plugin }) { p in
                row(name: p.displayName, badge: nil, badgeColor: .clear, detail: p.subtitle, available: true,
                    rechecking: false, onRecheck: nil, onRemove: nil)
            }
        }
    }

    private var codexComputerUseCard: some View {
        let connected = state.isCodexComputerUseConnected()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(connected ? Color.lingHolo : Color.lingFg.opacity(0.5))
                    .frame(width: 30, height: 30)
                    .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Computer Use")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.92))
                    Text(connected
                         ? "已从 Codex 官方插件清单确认，可查看并操作 Mac App"
                         : "复用本机 Codex 的官方能力；不复制组件，不绕过认证与授权")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.lingFg.opacity(0.5))
                }
                Spacer()
                Circle().fill(connected ? Color.green : Color.lingFg.opacity(0.25)).frame(width: 8, height: 8)
                Text(connected ? "已接入" : "未接入")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(connected ? Color.green : Color.lingFg.opacity(0.5))
                Button {
                    isConnectingComputerUse = true
                    computerUseMessage = ""
                    Task { @MainActor in
                        computerUseMessage = await state.connectCodexComputerUse()
                        isConnectingComputerUse = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isConnectingComputerUse { ProgressView().controlSize(.mini) }
                        else { Image(systemName: connected ? "arrow.clockwise" : "link.badge.plus") }
                        Text(isConnectingComputerUse ? "检测中…" : (connected ? "重新检测" : "接入"))
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isConnectingComputerUse)
            }
            if !computerUseMessage.isEmpty {
                Text(computerUseMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.isCodexComputerUseConnected() ? Color.lingHolo : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(connected ? Color.lingHolo.opacity(0.3) : Color.lingFg.opacity(0.08))
        }
    }

    @ViewBuilder private func groupTitle(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
            Text(sub).font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.45))
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func row(name: String, badge: String?, badgeColor: Color, detail: String,
                                  available: Bool, rechecking: Bool = false,
                                  onRecheck: (() -> Void)? = nil, onRemove: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Circle().fill(available ? Color.green : Color.red.opacity(0.7)).frame(width: 8, height: 8)
            Text("@\(name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lingFg)
            if let badge {
                Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.85), in: Capsule())
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if !available { Text("不可用").font(.system(size: 10)).foregroundStyle(.red.opacity(0.8)) }
            // 不可用 → 给「重新检测」按钮:重跑探活(登录/补凭据后点一下即恢复可用)。
            if let onRecheck {
                Button(action: onRecheck) {
                    HStack(spacing: 3) {
                        if rechecking { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold)) }
                        Text(rechecking ? "检测中…" : "重新检测").font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.lingHolo.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.lingHolo)
                }
                .buttonStyle(.plain).disabled(rechecking).help("重新探活这个 agent 是否可用")
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(Color.lingFg.opacity(0.5))
                    .help("从插件库移除")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
