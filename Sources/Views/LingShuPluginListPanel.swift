import SwiftUI

/// **插件列表**(配置 > 插件):看已接入的插件/agent。被告知本机有某 CLI agent → 注册成 agent 插件后,这里能查到;
/// 输入框 `@名字` 即可调用、编排(@Codex 开发 @Claude 验收)。可删已注册的 agent 插件。
struct LingShuPluginListPanel: View {
    @ObservedObject var state: LingShuState
    @State private var agents: [LingShuAgentPlugin] = []

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
                        detail: a.executable, available: a.isAvailableNow) {
                        LingShuAgentPluginStore.unregister(id: a.id)
                        reload()
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            // ── 内置插件 / 技能
            groupTitle("内置插件 / 技能", "随灵枢出厂或学会的能力,@名字 直接调")
            ForEach(state.invocablePlugins().filter { $0.kind == .plugin }) { p in
                row(name: p.displayName, badge: nil, badgeColor: .clear, detail: p.subtitle, available: true, onRemove: nil)
            }
        }
        .onAppear { reload() }
    }

    private func reload() { agents = LingShuAgentPluginStore.load() }

    @ViewBuilder private func groupTitle(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            .padding(.vertical, 6)
    }

    @ViewBuilder private func row(name: String, badge: String?, badgeColor: Color, detail: String,
                                  available: Bool, onRemove: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Circle().fill(available ? Color.green : Color.red.opacity(0.7)).frame(width: 8, height: 8)
            Text("@\(name)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            if let badge {
                Text(badge).font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.85), in: Capsule())
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if !available { Text("不可用").font(.system(size: 10)).foregroundStyle(.red.opacity(0.8)) }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "trash").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                    .help("从插件库移除")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
