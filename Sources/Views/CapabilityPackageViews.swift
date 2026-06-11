import SwiftUI

struct CapabilityPackageView: View {
    @ObservedObject var state: LingShuState

    private let departments: [CapabilityNode] = [
        .init(name: "需求节点", shortName: "需求", role: "需求澄清与目标建模", deliverable: "目标说明书", supervision: "阶段性检查目标是否跑偏", icon: "person.text.rectangle", color: .teal),
        .init(name: "项目节点", shortName: "推进", role: "项目推进与分工设计", deliverable: "推进计划与责任矩阵", supervision: "阶段性检查进度、依赖和风险", icon: "timeline.selection", color: .indigo),
        .init(name: "架构节点", shortName: "架构", role: "系统架构和技术决策", deliverable: "架构设计与接口契约", supervision: "检查实现是否破坏架构边界", icon: "square.stack.3d.up", color: .cyan),
        .init(name: "设计节点", shortName: "体验", role: "产品体验与交互设计", deliverable: "流程、界面和状态设计", supervision: "检查体验是否符合目标", icon: "rectangle.and.pencil.and.ellipsis", color: .purple),
        .init(name: "开发节点", shortName: "实现", role: "工程实现与集成", deliverable: "代码补丁与可运行产物", supervision: "按推进计划回传实现进度", icon: "chevron.left.forwardslash.chevron.right", color: .orange),
        .init(name: "测试节点", shortName: "验收", role: "质量门禁和验收测试", deliverable: "测试报告与缺陷清单", supervision: "最终验收，失败则退回相关能力节点", icon: "checklist.checked", color: .green)
    ]

    private let phases: [CapabilityPhase] = [
        .init(title: "1. 用户下达目标", owner: "灵枢", detail: "用户用语音或文字提交目标，灵枢确认边界和权限。", output: "任务契约", color: .brown),
        .init(title: "2. 目标建模", owner: "需求", detail: "需求节点把模糊目标整理成可验收说明。", output: "目标说明", color: .teal),
        .init(title: "3. 审议准入", owner: "灵枢 + 审议", detail: "审核目标清晰度、价值、风险、资源和是否启动。", output: "准入裁决", color: .red),
        .init(title: "4. 推进编排", owner: "项目", detail: "项目节点设计里程碑、分工、依赖和协作顺序。", output: "WBS / RACI", color: .indigo),
        .init(title: "5. 能力协作", owner: "按需能力节点", detail: "相关 agent 形成方案、界面、代码和集成结果。", output: "方案 / 代码 / 证据", color: .orange),
        .init(title: "6. 阶段监控", owner: "项目 + 需求", detail: "项目看进度，需求看目标，发现偏差就退回。", output: "阶段评审", color: .purple),
        .init(title: "7. 测试验收", owner: "测试", detail: "测试节点执行功能、回归、边界和验收测试。", output: "测试报告", color: .green),
        .init(title: "8. 最终交付", owner: "灵枢", detail: "灵枢汇总产物、测试结论、风险和下一步建议。", output: "交付包", color: .brown)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(icon: "person.badge.key", title: "软件工程能力包", subtitle: "软件工程只是首个能力包，能力节点负责从需求到交付的闭环")

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(icon: "person.badge.key.fill", title: "灵枢中枢位", subtitle: "用户只面对灵枢，灵枢再统筹必要能力节点")

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [.brown, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                                Image(systemName: "person.badge.key.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 68, height: 68)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("灵枢")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Color.lingInk)
                                Text("统一受令、裁决准入、授权执行、汇总结案。")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Color.lingMuted)
                            }
                        }

                        Divider()

                        Label("不直接替代能力节点，而是调用、制衡、审核和授权。", systemImage: "checkmark.seal")
                        Label("需求节点先给目标说明，项目节点再组织工程执行。", systemImage: "arrow.triangle.branch")
                        Label("项目与需求节点阶段性监控，测试节点负责最终质量门。", systemImage: "checklist.checked")
                    }
                    .font(.system(size: 12.8, weight: .medium))
                    .foregroundStyle(Color.lingInk.opacity(0.78))

                    Button {
                        state.startDemoMissionIfConnected()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("演示一次能力流转")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .foregroundStyle(.white)
                        .background(Color.lingInk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .panelStyle()

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(icon: "doc.text.magnifyingglass", title: "核心产物流", subtitle: "每一步都要有可审核的文档或产物")

                    ArtifactFlowRow(step: "需求", artifact: "目标说明书", detail: "目标、角色、场景、边界、验收标准")
                    ArtifactFlowRow(step: "灵枢", artifact: "审核裁决", detail: "是否立项、是否补充需求、风险等级")
                    ArtifactFlowRow(step: "项目", artifact: "推进分工", detail: "里程碑、依赖、负责人、交付节奏")
                    ArtifactFlowRow(step: "能力节点", artifact: "设计与实现", detail: "架构、交互、代码、测试用例")
                    ArtifactFlowRow(step: "测试", artifact: "验收报告", detail: "通过项、失败项、缺陷和回归结论")
                }
                .panelStyle()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(departments) { department in
                    CapabilityNodeCard(department: department)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(icon: "arrow.triangle.branch", title: "需求到交付闭环", subtitle: "这就是灵枢的软件工程起步能力")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(phases) { phase in
                        CapabilityPhaseCard(phase: phase)
                    }
                }
            }
            .panelStyle()
        }
    }
}

struct ArtifactFlowRow: View {
    let step: String
    let artifact: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.lingAccent)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(artifact)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.lingInk)
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
            }

            Spacer()
        }
        .padding(11)
        .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct CapabilityNodeCard: View {
    let department: CapabilityNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: department.icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(department.color)
                    .frame(width: 38, height: 38)
                    .background(department.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(department.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.lingInk)
                        Text(department.shortName)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(department.color)
                    }
                    Text(department.role)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.lingMuted)
                }

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Label(department.deliverable, systemImage: "doc.text")
                Label(department.supervision, systemImage: "eye")
            }
            .font(.system(size: 12.2, weight: .medium))
            .foregroundStyle(Color.lingInk.opacity(0.76))
        }
        .padding(15)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(department.color.opacity(0.20))
        }
    }
}

struct CapabilityPhaseCard: View {
    let phase: CapabilityPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(phase.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Color.lingInk)
                Spacer()
                Circle()
                    .fill(phase.color)
                    .frame(width: 8, height: 8)
            }

            Text(phase.owner)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(phase.color)

            Text(phase.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.lingMuted)
                .fixedSize(horizontal: false, vertical: true)

            Text(phase.output)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.lingInk.opacity(0.72))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.07))
        }
    }
}

struct A2AFlowRow: View {
    let index: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 38, height: 30)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.lingInk)
                Text(detail)
                    .font(.system(size: 12.2, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct CodeBlockView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.lingInk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
