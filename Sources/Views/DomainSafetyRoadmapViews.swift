import SwiftUI

struct AgentCard: View {
    let agent: LingShuAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: agent.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(agent.color)
                    .frame(width: 32, height: 32)
                    .background(agent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.lingInk)
                    Text(agent.domain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.lingFaint)
                }
                Spacer()
                Text(agent.state.rawValue)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(agent.state.color)
            }

            Text(agent.role)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.lingMuted)
                .lineLimit(2)

            ProgressView(value: agent.load)
                .tint(agent.color)
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.07))
        }
    }
}

struct DomainView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(icon: "square.grid.3x3", title: "能力域路线", subtitle: "软件工程只是起步场景，架构要能继续长出更多能力")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
                ForEach(state.domains) { domain in
                    DomainCard(domain: domain)
                }
            }
        }
        .panelStyle()
    }
}

struct DomainCard: View {
    let domain: CapabilityDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: domain.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(domain.color)
                    .frame(width: 38, height: 38)
                    .background(domain.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(domain.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.lingInk)
                    Text("\(Int(domain.maturity * 100))% ready")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(domain.color)
                }
                Spacer()
            }

            Text(domain.detail)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.lingMuted)
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: domain.maturity)
                .tint(domain.color)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(domain.modules, id: \.self) { module in
                    Text(module)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.lingInk.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(15)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.07))
        }
    }
}

struct SafetyView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(icon: "checkmark.shield", title: "安全与控制", subtitle: "通用助手要先可信，再强大")

                SafetyRule(icon: "hand.raised", title: "高风险操作需要确认", detail: "文件修改、终端命令、外部发送、购买和删除操作进入确认门。", color: .red)
                SafetyRule(icon: "clock.arrow.circlepath", title: "全链路审计日志", detail: "每个智能体的输入、输出、工具调用和结果都可追踪。", color: .orange)
                SafetyRule(icon: "person.crop.circle.badge.checkmark", title: "人类主权优先", detail: "灵枢负责建议和执行，最终授权留给用户。", color: .teal)
                SafetyRule(icon: "arrow.uturn.backward", title: "可回滚执行", detail: "软件工程域优先接入 Git diff、补丁预览和回滚策略。", color: .green)
            }
            .panelStyle()

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(icon: "lock.open.trianglebadge.exclamationmark", title: "权限矩阵", subtitle: "不同能力域的默认策略")

                PermissionRow(scope: "读取本地项目", level: "允许", color: .green)
                PermissionRow(scope: "运行测试命令", level: "确认", color: .orange)
                PermissionRow(scope: "修改源代码", level: "确认", color: .orange)
                PermissionRow(scope: "发送邮件消息", level: "确认", color: .red)
                PermissionRow(scope: "删除文件数据", level: "禁止", color: .red)
            }
            .panelStyle()
        }
    }
}

struct SafetyRule: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.lingInk)
                Text(detail)
                    .font(.system(size: 12.4, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PermissionRow: View {
    let scope: String
    let level: String
    let color: Color

    var body: some View {
        HStack {
            Text(scope)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.lingInk)
            Spacer()
            Text(level)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(12)
        .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct RoadmapView: View {
    private let phases: [(String, String, [String], Color)] = [
        ("阶段一", "对话式中枢原型", ["Mac 原生窗口", "灵枢对话入口", "软件工程能力域"], .teal),
        ("阶段二", "真实工具闭环", ["读取项目", "运行测试", "生成补丁", "人工确认"], .orange),
        ("阶段三", "智能体协议化", ["智能体名册", "任务契约", "消息总线", "产物仓库"], .cyan),
        ("阶段四", "通用助手扩展", ["日程邮件", "资料研究", "文档生产", "设备自动化"], .green)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(icon: "map", title: "研究与产品路线", subtitle: "把愿景收束成可验证的研究工作")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 14)], spacing: 14) {
                ForEach(phases, id: \.0) { phase in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(phase.0)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(phase.3)
                        Text(phase.1)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.lingInk)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(phase.2, id: \.self) { item in
                                Label(item, systemImage: "checkmark.circle")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Color.lingMuted)
                            }
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(minHeight: 210)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(phase.3.opacity(0.22))
                    }
                }
            }
        }
        .panelStyle()
    }
}

struct SectionHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.lingAccent)
                .frame(width: 30, height: 30)
                .background(Color.lingAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.system(size: 11.8, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
    }
}
