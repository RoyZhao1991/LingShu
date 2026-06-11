import AppKit
import SwiftUI

struct CommandCenterView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 18) {
            GridRow {
                LingShuConstellationView(agents: state.agents)
                    .gridCellColumns(2)
                    .frame(minHeight: 410)

                InvocationPanelView(state: state)
                    .frame(minHeight: 410)
            }

            GridRow {
                MissionTimelineView(steps: state.missionSteps)
                SupervisionBoardView(state: state)
                EventLogView(logs: state.eventLog)
            }
        }
    }
}

struct InvocationPanelView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "waveform", title: "召唤入口", subtitle: "Siri / 快捷键 / 菜单栏 / 语音会话")

            VStack(alignment: .leading, spacing: 10) {
                Text(state.missionTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.lingInk)
                Text(state.missionStatus)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ReturnSubmittingTextEditor(
                text: $state.prompt,
                foregroundColor: NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.11, alpha: 1),
                fontSize: 14,
                onSubmit: {
                    _ = state.sendPrompt()
                }
            )
                .padding(10)
                .frame(height: 112)
                .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.08))
                }

            HStack(spacing: 10) {
                Button {
                    state.toggleListening()
                } label: {
                    Image(systemName: state.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 42, height: 38)
                        .foregroundStyle(.white)
                        .background(state.isListening ? Color.red : Color.teal, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("模拟语音唤醒")

                Button {
                    state.startDemoMissionIfConnected()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                        Text("编排任务")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .foregroundStyle(.white)
                    .background(Color.lingInk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                CompactMetric(label: "可用智能体", value: "8", icon: "person.3.sequence")
                CompactMetric(label: "运行期", value: state.runtimePhase.rawValue, icon: state.runtimePhase.icon)
                CompactMetric(label: "监工线程", value: "\(state.activeSupervisorCount)", icon: "eye")
                CompactMetric(label: "巡检轮次", value: "\(state.supervisionTick)", icon: "timer")
            }

            Spacer()
        }
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.07))
        }
    }
}

struct CompactMetric: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.lingMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.lingInk)
        }
    }
}

struct LingShuConstellationView: View {
    let agents: [LingShuAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "brain.head.profile", title: "灵枢中枢", subtitle: "统一体验背后的多智能体协作网")

            GeometryReader { proxy in
                let size = proxy.size
                let center = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
                let radius = min(size.width, size.height) * 0.34

                ZStack {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        let angle = Double(index) / Double(max(agents.count, 1)) * 2 * Double.pi - Double.pi / 2
                        let point = CGPoint(
                            x: center.x + CGFloat(cos(angle)) * radius,
                            y: center.y + CGFloat(sin(angle)) * radius
                        )

                        Path { path in
                            path.move(to: center)
                            path.addLine(to: point)
                        }
                        .stroke(agent.mode != .dormant ? agent.mode.color.opacity(0.75) : Color.black.opacity(0.08), style: StrokeStyle(lineWidth: agent.mode != .dormant ? 2.8 : 1.2, dash: agent.mode == .dormant ? [4, 5] : []))

                        AgentNodeView(agent: agent)
                            .position(point)
                    }

                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [Color.lingInk, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 132, height: 132)
                                .shadow(color: Color.teal.opacity(0.24), radius: 20, x: 0, y: 10)
                            Circle()
                                .stroke(Color.white.opacity(0.72), lineWidth: 1)
                                .frame(width: 112, height: 112)
                            VStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 24, weight: .bold))
                                Text("灵枢")
                                    .font(.system(size: 18, weight: .bold))
                                Text("中枢")
                                    .font(.system(size: 11, weight: .semibold))
                                    .opacity(0.75)
                            }
                            .foregroundStyle(.white)
                        }

                        Text("受令 -> 调度 -> 并行执行 -> 周期监工 -> 裁决")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.lingMuted)
                    }
                    .position(center)
                }
            }
        }
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.07))
        }
    }
}

struct AgentNodeView: View {
    let agent: LingShuAgent

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(agent.mode.color.opacity(agent.mode == .dormant ? 0.10 : 0.22))
                    .frame(width: 70, height: 70)
                Circle()
                    .stroke(agent.mode == .dormant ? Color.black.opacity(0.12) : agent.mode.color, lineWidth: agent.mode == .dormant ? 1 : 2.2)
                    .frame(width: 62, height: 62)
                Image(systemName: agent.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(agent.color)
            }

            VStack(spacing: 2) {
                Text(agent.shortName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.lingInk)
                Text(agent.state.rawValue)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(agent.mode == .dormant ? Color.lingFaint : agent.mode.color)
                Text(agent.mode.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(agent.mode == .dormant ? Color.lingFaint : agent.mode.color)
            }
        }
        .frame(width: 92)
    }
}

struct MissionTimelineView: View {
    let steps: [MissionStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "list.bullet.rectangle", title: "任务链", subtitle: "一次召唤如何被拆解")

            VStack(spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(step.state.color.opacity(0.16))
                            Image(systemName: step.state.icon)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(step.state.color)
                        }
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(step.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.lingInk)
                                Spacer()
                                Text(step.agent)
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(step.state.color)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(step.state.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            Text(step.detail)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.lingMuted)
                                .lineLimit(2)
                        }
                    }

                    if index != steps.count - 1 {
                        Rectangle()
                            .fill(Color.black.opacity(0.08))
                            .frame(width: 1, height: 8)
                            .padding(.leading, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .panelStyle()
    }
}

struct SupervisionBoardView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "eye", title: "并行监工", subtitle: "执行期的周期巡检与纠偏事件")

            HStack(spacing: 9) {
                RuntimeBadge(title: state.runtimePhase.rawValue, icon: state.runtimePhase.icon, color: state.runtimePhase.color)
                RuntimeBadge(title: "\(state.activeSupervisorCount) 监工", icon: "person.3.sequence", color: .teal)
                RuntimeBadge(title: "\(state.supervisionTick) 轮", icon: "timer", color: .orange)
            }

            VStack(spacing: 9) {
                ForEach(state.agents.filter { $0.mode == .supervising || $0.mode == .correcting || $0.mode == .verifying }.prefix(5)) { agent in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: agent.mode.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(agent.mode.color)
                            .frame(width: 26, height: 26)
                            .background(agent.mode.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(agent.shortName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.lingInk)
                                Text(agent.cadence)
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(agent.mode.color)
                            }
                            Text(agent.focus)
                                .font(.system(size: 11.3, weight: .medium))
                                .foregroundStyle(Color.lingMuted)
                                .lineLimit(1)
                            Text(agent.lastFinding)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.lingMuted.opacity(0.86))
                                .lineLimit(2)
                        }

                        Spacer()
                    }
                    .padding(9)
                    .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if state.supervisorEvents.isEmpty {
                Text("任务进入执行期后，监控、审议、验证会按节拍巡检。")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lingPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(state.supervisorEvents.prefix(3)) { event in
                        SupervisorEventRow(event: event)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .panelStyle()
    }
}

struct RuntimeBadge: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct SupervisorEventRow: View {
    let event: SupervisorEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("#\(event.tick)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(event.severity.eventColor)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.agent)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(event.severity.eventColor)
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.lingInk)
                }
                Text(event.detail)
                    .font(.system(size: 10.8, weight: .medium))
                    .foregroundStyle(Color.lingMuted)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(9)
        .background(event.severity.eventColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
