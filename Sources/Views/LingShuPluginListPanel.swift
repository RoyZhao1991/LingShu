import SwiftUI

/// **插件列表**(配置 > 插件):看已接入的插件/agent。被告知本机有某 CLI agent → 注册成 agent 插件后,这里能查到;
/// 输入框 `@名字` 即可调用、编排(@Codex 开发 @Claude 验收)。可删已注册的 agent 插件。
struct LingShuPluginListPanel: View {
    @ObservedObject var state: LingShuState
    @State private var agents: [LingShuAgentPlugin] = []
    @State private var rechecking: Set<String> = []   // 正在重新探活的 agent id

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "square.grid.2x2", title: "插件列表",
                          subtitle: "已接入的插件 / agent —— 输入框点「+」或打 @名字 即可调用、编排(@Codex 开发 @Claude 验收)")

            // ── Agent 插件(被告知→注册)。**agent 就是 agent,不带固定 maker/checker 角色**——
            // 角色(谁开发、谁验收、几个验收)由灵枢**按每个任务的语义临时装配**(codex 能当 checker、claude 能当 maker)。
            groupTitle("Agent 插件", "被告知本机有某 CLI agent → 注册进插件库;@名字 委托,角色(maker/checker)由灵枢按任务语义临时装配")
            if agents.isEmpty {
                hint("还没注册 agent。跟灵枢说「本机有 X,可执行 …,调用 …,用 register_agent 注册」即可。")
            } else {
                ForEach(agents) { a in
                    row(name: a.displayName, badge: "agent", badgeColor: .lingHolo,
                        detail: a.executable, available: a.isAvailableNow,
                        rechecking: rechecking.contains(a.id),
                        onRecheck: a.isAvailableNow ? nil : { recheck(a) },
                        onRemove: {
                            LingShuAgentPluginStore.unregister(id: a.id)
                            reload()
                        })
                }
            }

            Divider().overlay(Color.lingFg.opacity(0.08))

            // ── 内置插件 / 技能
            groupTitle("内置插件 / 技能", "随灵枢出厂或学会的能力,@名字 直接调")
            ForEach(state.invocablePlugins().filter { $0.kind == .plugin }) { p in
                row(name: p.displayName, badge: nil, badgeColor: .clear, detail: p.subtitle, available: true,
                    rechecking: false, onRecheck: nil, onRemove: nil)
            }
        }
        .onAppear { reload() }
    }

    private func reload() { agents = LingShuAgentPluginStore.load() }

    @ViewBuilder private func groupTitle(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
            Text(sub).font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.45))
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(Color.lingFg.opacity(0.5))
            .padding(.vertical, 6)
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

    /// 重新探活一个 agent:跑 probeAvailability(短超时实跑一次,检测登录/认证),通过→标可用,否则→保持不可用 + 原因。
    private func recheck(_ plugin: LingShuAgentPlugin) {
        rechecking.insert(plugin.id)
        let wd = state.agentWorkingDirectory
        Task {
            let result = await LingShuAgentPluginStore.probeAvailability(plugin, workingDirectory: wd)
            await MainActor.run {
                if result.ok { _ = LingShuAgentPluginStore.markAvailable(id: plugin.id) }
                else { _ = LingShuAgentPluginStore.markUnavailable(id: plugin.id, reason: result.reason) }
                rechecking.remove(plugin.id)
                reload()
                state.appendTrace(kind: result.ok ? .result : .warning, actor: "插件",
                                  title: "重新探活·\(plugin.displayName)",
                                  detail: result.ok ? "恢复可用" : "仍不可用:\(result.reason)")
            }
        }
    }
}
