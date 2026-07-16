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
        case skills = "技能"
        case plugins = "插件"
        case connectors = "连接器"
        case memory = "记忆"
        case selfCheck = "自检"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .model: "antenna.radiowaves.left.and.right"
            case .policy: "gearshape"
            case .residency: "clock.badge"
            case .skills: "puzzlepiece.extension"
            case .plugins: "square.grid.2x2"
            case .connectors: "app.connected.to.app.below.fill"
            case .memory: "brain"
            case .selfCheck: "scope"
            }
        }
        var englishName: String {
            switch self {
            case .model: "Models"
            case .policy: "System"
            case .residency: "Standby & Triggers"
            case .skills: "Skills"
            case .plugins: "Plugins"
            case .connectors: "Connectors"
            case .memory: "Memory"
            case .selfCheck: "Self-check"
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
                        .foregroundStyle(tab == item ? Color.lingVoid : Color.lingFg.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            tab == item ? Color.lingHolo : Color.lingFg.opacity(0.05),
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

            Divider().overlay(Color.lingFg.opacity(0.08))

            Group {
                switch tab {
                case .model:
                    LingShuModelGatewaySurface(state: state)
                case .policy:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            LingShuExecutionPolicySurface(state: state)
                            Divider()
                            LingShuPermissionMatrixView()   // #5 权限矩阵可视化
                        }
                        .padding(22)
                    }
                case .residency:
                    ScrollView {
                        LingShuTriggerSettingsView(state: state, triggerService: state.scheduledTriggers)
                            .padding(22)
                    }
                case .skills:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            LingShuSkillsPanel(state: state)
                            Divider()
                            LingShuExtensionsPanel(state: state)   // P5 统一扩展管理(技能+连接器:启停/权限/效能)
                            Divider()
                            LingShuModuleVariantsPanel(state: state)   // P6+ 无界自进化:模块变体治理(切换/回退)
                        }
                        .padding(22)
                    }
                case .plugins:
                    ScrollView { LingShuPluginListPanel(state: state).padding(22) }
                case .connectors:
                    LingShuConnectorsHub(state: state)
                case .memory:
                    ScrollView {
                        LingShuMemoryStatsPanel(state: state)
                            .padding(22)
                    }
                case .selfCheck:
                    ScrollView { LingShuSelfCheckPanel(state: state).padding(22) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 连接器中心（MCP 连接器 / 外设连接器 两个子 tab）

/// 「连接器」= 灵枢对接外部能力的两类通道:**MCP 连接器**(软件工具 server)与
/// **外设连接器**(硬件/外接设备,如 iPhone 蓝牙通知桥 ANCS)。两者各一个子 tab。
struct LingShuConnectorsHub: View {
    @ObservedObject var state: LingShuState

    enum Sub: String, CaseIterable, Identifiable {
        case mcp = "MCP 连接器"
        case peripheral = "感知连接器"
        case home = "已连接外设"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .mcp: "app.connected.to.app.below.fill"
            case .peripheral: "sensor.tag.radiowaves.forward"
            case .home: "cpu"
            }
        }
        var englishName: String {
            switch self {
            case .mcp: "MCP"
            case .peripheral: "Sensing"
            case .home: "Peripherals"
            }
        }
    }

    @State private var sub: Sub = .mcp

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Sub.allCases) { item in
                    Button {
                        sub = item
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(state.loc(item.rawValue, item.englishName))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(sub == item ? Color.lingVoid : Color.lingFg.opacity(0.7))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            sub == item ? Color.lingHolo : Color.lingFg.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                switch sub {
                case .mcp:
                    LingShuConnectorsPanel(state: state, registry: state.connectorRegistry).padding(22)
                case .peripheral:
                    LingShuExternalSensoryView(state: state, hub: state.externalSensory).padding(22)
                case .home:
                    LingShuPeripheralsView(state: state, hub: state.peripheralHub).padding(22)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 技能面板（用户自定义专家）

struct LingShuSkillsPanel: View {
    @ObservedObject var state: LingShuState

    private var profiles: [LingShuExpertProfile] { state.expertProfileRegistry.allProfiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                icon: "puzzlepiece.extension",
                title: state.loc("专家技能", "Expert Skills"),
                subtitle: state.loc("内置专家 + 用户自定义 .md 技能（触发词命中时优先）", "Built-in experts and user-defined .md skills")
            )

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(LingShuSkillLoader.defaultDirectory)
                } label: {
                    Label(state.loc("打开技能目录", "Open Skills Folder"), systemImage: "folder")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                Text(state.loc(
                    "放入带 frontmatter（title/triggers）的 .md 文件，重启后生效。",
                    "Add .md files with title/triggers frontmatter, then restart LingShu."
                ))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.45))
            }

            ForEach(profiles, id: \.id) { profile in
                HStack(spacing: 10) {
                    Image(systemName: profile.id.hasPrefix("skill-") ? "person.crop.circle.badge.plus" : "person.crop.circle")
                        .foregroundStyle(profile.id.hasPrefix("skill-") ? Color.lingHoloAlt : Color.lingHolo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.title)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.lingFg.opacity(0.9))
                        Text(profile.mission)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.lingFg.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(profile.id.hasPrefix("skill-") ? state.loc("用户", "User") : state.loc("内置", "Built-in"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.5))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.lingFg.opacity(0.07), in: Capsule())
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
    }
}

// MARK: - 连接器面板（MCP）

struct LingShuConnectorsPanel: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var registry: LingShuConnectorRegistry
    @State private var name = ""
    @State private var command = ""
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                icon: "app.connected.to.app.below.fill",
                title: state.loc("MCP 连接器", "MCP Connectors"),
                subtitle: state.loc("把外部 MCP server 工具接入协同管线", "Connect external MCP server tools to the agent pipeline")
            )

            HStack(spacing: 8) {
                TextField(state.loc("名称", "Name"), text: $name).textFieldStyle(.roundedBorder).frame(width: 120)
                TextField(state.loc("启动命令，例如：npx -y @modelcontextprotocol/server-filesystem /path", "Command, for example: npx -y @modelcontextprotocol/server-filesystem /path"), text: $command)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let parts = command.split(separator: " ").map(String.init)
                    guard let first = parts.first else { return }
                    registry.addServer(name: name, command: first, arguments: Array(parts.dropFirst()))
                    name = ""; command = ""
                } label: { Label(state.loc("添加", "Add"), systemImage: "plus.circle.fill").font(.system(size: 11.5, weight: .bold)) }
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    isRefreshing = true
                    Task { await registry.refreshTools(); isRefreshing = false }
                } label: { Label(isRefreshing ? state.loc("探测中…", "Discovering…") : state.loc("探测工具", "Discover Tools"), systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11.5, weight: .semibold)) }
                .disabled(isRefreshing || registry.servers.isEmpty)
            }

            if registry.servers.isEmpty {
                Text(state.loc(
                    "还没有连接器。MCP server 可以让灵枢读取 Issue、查询数据库或调用外部服务。",
                    "No connectors yet. MCP servers can let LingShu read issues, query databases, or call external services."
                ))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.4))
            } else {
                ForEach(registry.servers) { server in
                    HStack(spacing: 10) {
                        Circle().fill(server.enabled ? Color.lingHolo : Color.lingFg.opacity(0.25)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
                            Text("\(server.command) \(server.arguments.joined(separator: " "))")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.lingFg.opacity(0.45)).lineLimit(1)
                        }
                        Spacer()
                        let toolCount = registry.discoveredTools.filter { $0.serverID == server.id }.count
                        if toolCount > 0 {
                            Text(state.loc("\(toolCount) 工具", "\(toolCount) tools")).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color.lingHolo)
                        }
                        Toggle("", isOn: Binding(get: { server.enabled }, set: { registry.setEnabled(id: server.id, enabled: $0) }))
                            .toggleStyle(.switch).controlSize(.mini)
                        Button { registry.removeServer(id: server.id) } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red.opacity(0.7))
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
    }
}

// MARK: - 记忆面板

struct LingShuMemoryStatsPanel: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "brain", title: state.loc("记忆", "Memory"), subtitle: state.loc("本地知识图谱 + 本机知识索引 + 经验资产", "Local knowledge graph, index, and experience assets"))

            let stats = state.memoryDashboardStats()
            HStack(spacing: 12) {
                statCard(title: state.loc("图谱节点", "Graph nodes"), value: "\(stats.graphNodes)", hint: state.loc("本地 Markdown vault", "Local Markdown vault"))
                statCard(title: state.loc("经验资产", "Experience assets"), value: "\(stats.experienceAssets)", hint: experienceHint(stats))
                statCard(title: state.loc("任务记录", "Task records"), value: "\(stats.retainedTaskRecords)", hint: state.loc("热 \(stats.hotTaskRecords) · 冷 \(stats.coldTaskRecords)", "Hot \(stats.hotTaskRecords) · Cold \(stats.coldTaskRecords)"))
            }

            Text(state.loc(
                "图谱节点来自长期记忆 vault；经验资产来自已完成任务的结构化沉淀，任务记录用于回放和续接。",
                "Graph nodes come from the local long-term memory vault. Experience assets are distilled from completed tasks, while retained task records support replay and continuation."
            ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            LingShuKnowledgeGraphView(state: state)
        }
        .padding(14)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.14)) }
    }

    private func experienceHint(_ stats: LingShuMemoryDashboardStats) -> String {
        var parts = [state.loc("经验 \(stats.goalExperiences)", "Goals \(stats.goalExperiences)"), state.loc("规则 \(stats.experienceRules)", "Rules \(stats.experienceRules)")]
        if stats.pendingExperienceBackfill > 0 {
            parts.append(state.loc("待回填 \(stats.pendingExperienceBackfill)", "Pending \(stats.pendingExperienceBackfill)"))
        }
        return parts.joined(separator: " · ")
    }

    private func statCard(title: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Color.lingHolo)
            Text(title).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.8))
            Text(hint).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.42))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.lingFg.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
