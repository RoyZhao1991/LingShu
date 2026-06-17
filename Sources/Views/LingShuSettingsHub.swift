import SwiftUI
import AppKit

/// 设置中心：二级菜单分区，避免所有配置堆在一个滚动条里糊成一面墙。
/// 模型通道 / 常驻与触发 / 技能与连接器 / 记忆，各自独立页签。
struct LingShuSettingsHub: View {
    @ObservedObject var state: LingShuState

    enum Tab: String, CaseIterable, Identifiable {
        case model = "模型通道"
        case policy = "系统配置"
        case residency = "常驻与触发"
        case skills = "技能与连接器"
        case memory = "记忆"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .model: "antenna.radiowaves.left.and.right"
            case .policy: "gearshape"
            case .residency: "clock.badge"
            case .skills: "puzzlepiece.extension"
            case .memory: "brain"
            }
        }
        var englishName: String {
            switch self {
            case .model: "Models"
            case .policy: "System"
            case .residency: "Standby & Triggers"
            case .skills: "Skills & Connectors"
            case .memory: "Memory"
            }
        }
    }

    @State private var tab: Tab = .model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(state.loc(item.rawValue, item.englishName))
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(tab == item ? Color.lingVoid : .white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            tab == item ? Color.lingHolo : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider().overlay(Color.white.opacity(0.08))

            Group {
                switch tab {
                case .model:
                    LingShuModelGatewaySurface(state: state)
                case .policy:
                    ScrollView {
                        LingShuExecutionPolicySurface(state: state).padding(22)
                    }
                case .residency:
                    ScrollView {
                        LingShuTriggerSettingsView(triggerService: state.scheduledTriggers)
                            .padding(22)
                    }
                case .skills:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            LingShuSkillsPanel(state: state)
                            LingShuConnectorsPanel(registry: state.connectorRegistry)
                        }
                        .padding(22)
                    }
                case .memory:
                    ScrollView {
                        LingShuMemoryStatsPanel(state: state)
                            .padding(22)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 技能面板（用户自定义专家）

struct LingShuSkillsPanel: View {
    @ObservedObject var state: LingShuState

    private var profiles: [LingShuExpertProfile] { state.expertProfileRegistry.allProfiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "puzzlepiece.extension", title: "专家技能", subtitle: "内置专家 + 用户自定义 .md 技能（触发词命中时优先）")

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(LingShuSkillLoader.defaultDirectory)
                } label: {
                    Label("打开技能目录", systemImage: "folder")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                Text("放入带 frontmatter（title/triggers）的 .md 文件，重启后生效。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ForEach(profiles, id: \.id) { profile in
                HStack(spacing: 10) {
                    Image(systemName: profile.id.hasPrefix("skill-") ? "person.crop.circle.badge.plus" : "person.crop.circle")
                        .foregroundStyle(profile.id.hasPrefix("skill-") ? Color.lingHoloAlt : Color.lingHolo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.title)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(profile.mission)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(profile.id.hasPrefix("skill-") ? "用户" : "内置")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
    }
}

// MARK: - 连接器面板（MCP）

struct LingShuConnectorsPanel: View {
    @ObservedObject var registry: LingShuConnectorRegistry
    @State private var name = ""
    @State private var command = ""
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "app.connected.to.app.below.fill", title: "MCP 连接器", subtitle: "接外部 MCP server 的工具进协同管线（数据库 / API / Slack 等）")

            HStack(spacing: 8) {
                TextField("名称", text: $name).textFieldStyle(.roundedBorder).frame(width: 120)
                TextField("启动命令，例如：npx -y @modelcontextprotocol/server-filesystem /path", text: $command)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let parts = command.split(separator: " ").map(String.init)
                    guard let first = parts.first else { return }
                    registry.addServer(name: name, command: first, arguments: Array(parts.dropFirst()))
                    name = ""; command = ""
                } label: { Label("添加", systemImage: "plus.circle.fill").font(.system(size: 11.5, weight: .bold)) }
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    isRefreshing = true
                    Task { await registry.refreshTools(); isRefreshing = false }
                } label: { Label(isRefreshing ? "探测中…" : "探测工具", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11.5, weight: .semibold)) }
                .disabled(isRefreshing || registry.servers.isEmpty)
            }

            if registry.servers.isEmpty {
                Text("还没有连接器。MCP server 让灵枢能读 issue、查数据库、发消息——为一个写的连接器在 Claude Code/Codex 里通常也能直接用。")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(registry.servers) { server in
                    HStack(spacing: 10) {
                        Circle().fill(server.enabled ? Color.lingHolo : Color.white.opacity(0.25)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                            Text("\(server.command) \(server.arguments.joined(separator: " "))")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        Spacer()
                        let toolCount = registry.discoveredTools.filter { $0.serverID == server.id }.count
                        if toolCount > 0 {
                            Text("\(toolCount) 工具").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color.lingHolo)
                        }
                        Toggle("", isOn: Binding(get: { server.enabled }, set: { registry.setEnabled(id: server.id, enabled: $0) }))
                            .toggleStyle(.switch).controlSize(.mini)
                        Button { registry.removeServer(id: server.id) } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red.opacity(0.7))
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
    }
}

// MARK: - 记忆面板

struct LingShuMemoryStatsPanel: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "brain", title: "记忆", subtitle: "语义库 + 经验规则（任务失败提炼的通用规则，复利增长）")

            let ruleCount = state.memoryService.experienceRuleCount
            HStack(spacing: 12) {
                statCard(title: "经验规则", value: "\(ruleCount)", hint: "被打回的任务自动沉淀")
                statCard(title: "热聊天历史", value: "\(state.chatMessages.count)", hint: "当前会话气泡")
                statCard(title: "任务记录", value: "\(state.taskExecutionRecordLookup.count)", hint: "可回放的执行流程")
            }

            Text("经验规则来自协同管线：任务被评审打回又修正后，灵枢把「问题→修正」提炼成一句通用规则写入语义库，下次同领域任务的规划阶段自动参考——记忆从流水账变成复利。")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
    }

    private func statCard(title: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Color.lingHolo)
            Text(title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            Text(hint).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
