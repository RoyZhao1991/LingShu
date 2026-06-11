import SwiftUI

struct ArchitectureLayersView: View {
    private let layers: [(String, String, String, Color)] = [
        ("交互层", "Mac App / Siri / 快捷键 / 语音", "macwindow", .teal),
        ("灵枢层", "通用中枢 / 承令 / 裁决 / 授权", "person.badge.key", .brown),
        ("治理层", "规划 / 审议 / 调度的制衡链路", "building.columns", .indigo),
        ("通信协议层", "节点发现 / 委托 / 消息 / 状态", "network", .cyan),
        ("能力节点层", "执行 / 监控 / 验证 / 记忆 / 安全 / 知识", "hammer", .orange),
        ("工具层", "Git / Shell / IDE / 浏览器 / 文件", "wrench.and.screwdriver", .green)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "rectangle.3.group", title: "系统分层", subtitle: "通用中枢的论文主线")

            VStack(spacing: 9) {
                ForEach(layers, id: \.0) { layer in
                    HStack(spacing: 10) {
                        Image(systemName: layer.2)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(layer.3)
                            .frame(width: 26, height: 26)
                            .background(layer.3.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layer.0)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.lingInk)
                            Text(layer.1)
                                .font(.system(size: 11.3, weight: .medium))
                                .foregroundStyle(Color.lingMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(9)
                    .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Spacer(minLength: 0)
        }
        .panelStyle()
    }
}

struct EventLogView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "terminal", title: "审计日志", subtitle: "可追踪的智能体行为")

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(logs.prefix(7).enumerated()), id: \.offset) { _, log in
                    Text(log)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.lingInk.opacity(0.78))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            Spacer(minLength: 0)
        }
        .panelStyle()
    }
}

struct A2AProtocolView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(icon: "point.3.connected.trianglepath.dotted", title: "智能体通信协议", subtitle: "让不同智能体可以发现、委托、协作和回传")

                    A2AFlowRow(index: "01", title: "智能体名册", detail: "声明身份、能力、输入输出、权限边界。", color: .teal)
                    A2AFlowRow(index: "02", title: "任务契约", detail: "把用户目标转成可验证任务契约。", color: .orange)
                    A2AFlowRow(index: "03", title: "消息总线", detail: "在智能体之间传递上下文、状态和结果。", color: .cyan)
                    A2AFlowRow(index: "04", title: "产物回传", detail: "返回补丁、报告、日志、确认项和证据。", color: .green)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(icon: "tray.2", title: "消息示例", subtitle: "原型里的智能体任务包")
                    CodeBlockView(text:
"""
{
  "发令者": "用户",
  "中枢": "灵枢",
  "任务": "能力协作任务",
  "策略": "需要灵枢裁可",
  "能力节点": ["规划", "审议", "调度", "执行", "监控", "验证"],
  "产物": ["任务草案", "权限裁决", "执行计划", "产物输出", "验证报告"]
}
"""
                    )
                }
                .panelStyle()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                ForEach(state.agents) { agent in
                    AgentCard(agent: agent)
                }
            }
        }
    }
}

struct GovernanceView: View {
    private let provinces: [(String, String, String, String, Color)] = [
        ("规划", "计划节点", "起草与生成", "负责理解用户意图、形成任务草案、提出多智能体协作计划。", .teal),
        ("审议", "审核节点", "风险与权限", "负责风险判断、事实校验、权限审查和反对意见生成。", .red),
        ("调度", "执行调度", "分派与落地", "负责把已批准的计划分发到能力域，调用工具并沉淀结果。", .orange)
    ]

    private let ministries: [(String, String, String, String, Color)] = [
        ("名册", "智能体注册", "能力画像、角色管理、输入输出契约。", "person.badge.key", .indigo),
        ("资源", "资源账本", "成本、上下文、记忆、资源配额。", "chart.bar.doc.horizontal", .green),
        ("交互", "表达协议", "用户交互、智能体礼仪、文档表达。", "text.bubble", .teal),
        ("执行", "任务执行", "任务执行、应急响应、外部工具调度。", "bolt.shield", .orange),
        ("安全", "安全审议", "安全审计、合规判断、越权拦截。", "exclamationmark.shield", .red),
        ("能力", "能力包", "软件工程、自动化工具、资料研究等可扩展能力。", "hammer", .brown)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(icon: "building.columns", title: "通用智能体治理", subtitle: "灵枢是对话式中枢，负责承令、统筹、裁决和验收；能力节点负责制衡与执行")

            EmperorOverviewCard()

            HStack(alignment: .top, spacing: 16) {
                ForEach(provinces, id: \.0) { province in
                    ProvinceCard(
                        historicalName: province.0,
                        lingShuName: province.1,
                        responsibility: province.2,
                        detail: province.3,
                        color: province.4
                    )
                }
            }

            HStack(spacing: 10) {
                GovernanceArrow(title: "起草")
                GovernanceArrow(title: "审核")
                GovernanceArrow(title: "执行")
                GovernanceArrow(title: "回奏")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(ministries, id: \.0) { ministry in
                    MinistryCard(
                        name: ministry.0,
                        systemName: ministry.1,
                        detail: ministry.2,
                        icon: ministry.3,
                        color: ministry.4
                    )
                }
            }
        }
        .panelStyle()
    }
}

struct EmperorOverviewCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.brown, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 6) {
                Text("灵枢 = 通用中枢")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.lingInk)
                Text("用户只向灵枢下达指令。灵枢负责判断任务性质、调用能力节点、审核关键产物、授权执行，并把最终结果统一交付给用户。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Label("受令", systemImage: "quote.bubble")
                Label("裁决", systemImage: "checkmark.seal")
                Label("调度", systemImage: "arrow.triangle.branch")
                Label("交付", systemImage: "shippingbox")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.lingInk.opacity(0.76))
            .frame(width: 110, alignment: .leading)
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.brown.opacity(0.22))
        }
    }
}

struct ProvinceCard: View {
    let historicalName: String
    let lingShuName: String
    let responsibility: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(historicalName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.lingInk)
                    Text(lingShuName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                }
                Spacer()
                Image(systemName: "seal")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
            }

            Text(responsibility)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.lingInk.opacity(0.8))

            Text(detail)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.lingMuted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 172)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.24))
        }
    }
}

struct GovernanceArrow: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.lingInk.opacity(0.74))
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.lingFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct MinistryCard: View {
    let name: String
    let systemName: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.lingInk)
                    Text(systemName)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                }

                Text(detail)
                    .font(.system(size: 12.3, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.07))
        }
    }
}
