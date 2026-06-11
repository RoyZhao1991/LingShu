import SwiftUI

struct OperationsConsoleView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        HStack(spacing: 0) {
            OperationsTreeSidebar(selected: $state.selectedNav)

            ScrollView {
                VStack(spacing: 18) {
                    switch state.selectedNav {
                    case .command:
                        CommandCenterView(state: state)
                    case .a2a:
                        A2AProtocolView(state: state)
                    case .governance:
                        GovernanceView()
                    case .capabilityPackage:
                        CapabilityPackageView(state: state)
                    case .domains:
                        DomainView(state: state)
                    case .safety:
                        SafetyView(state: state)
                    case .roadmap:
                        RoadmapView()
                    }
                }
                .padding(22)
            }
        }
    }
}

struct OperationsTreeSidebar: View {
    @Binding var selected: NavItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("运维视图")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text("组织、协议、审计与能力配置")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TreeButton(title: "运行态势", icon: "speedometer", item: .command, selected: $selected)

                    DisclosureGroup {
                        TreeButton(title: "治理链路总览", icon: "building.columns", item: .governance, selected: $selected)
                        TreeLeafText("规划：任务草案")
                        TreeLeafText("审议：风险与权限")
                        TreeLeafText("调度：分派与汇总")
                    } label: {
                        TreeGroupLabel(title: "治理链路")
                    }

                    DisclosureGroup {
                        TreeButton(title: "能力包总览", icon: "hammer", item: .capabilityPackage, selected: $selected)
                        TreeLeafText("执行")
                        TreeLeafText("监控")
                        TreeLeafText("验证")
                        TreeLeafText("记忆")
                        TreeLeafText("安全")
                        TreeLeafText("知识")
                    } label: {
                        TreeGroupLabel(title: "能力包")
                    }

                    DisclosureGroup {
                        TreeButton(title: "能力域", icon: "square.grid.3x3", item: .domains, selected: $selected)
                        TreeButton(title: "智能体通信", icon: "point.3.connected.trianglepath.dotted", item: .a2a, selected: $selected)
                        TreeButton(title: "安全审计", icon: "checkmark.shield", item: .safety, selected: $selected)
                        TreeButton(title: "路线规划", icon: "map", item: .roadmap, selected: $selected)
                    } label: {
                        TreeGroupLabel(title: "底层能力")
                    }
                }
                .font(.system(size: 13, weight: .medium))
            }

            Spacer()

            Text("普通用户主入口是对话；此处用于调试、答辩演示和系统治理。")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
        .frame(width: 246)
        .background(Color.lingSidebar)
    }
}

struct TreeGroupLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.vertical, 7)
    }
}

struct TreeButton: View {
    let title: String
    let icon: String
    let item: NavItem
    @Binding var selected: NavItem

    var body: some View {
        Button {
            selected = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 9)
            .foregroundStyle(selected == item ? Color.lingInk : .white.opacity(0.76))
            .background(selected == item ? Color.white : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct TreeLeafText: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.58))
            .padding(.leading, 18)
            .padding(.vertical, 3)
    }
}
