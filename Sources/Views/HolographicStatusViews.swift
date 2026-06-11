import SwiftUI

struct TechGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let grid: CGFloat = 38
            var path = Path()

            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += grid
            }

            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += grid
            }

            context.stroke(path, with: .color(Color.lingHolo.opacity(0.055)), lineWidth: 1)

            var scan = Path()
            let scanY = size.height * 0.34
            scan.move(to: CGPoint(x: 0, y: scanY))
            scan.addLine(to: CGPoint(x: size.width, y: scanY))
            context.stroke(scan, with: .color(Color.lingHolo.opacity(0.18)), lineWidth: 1.2)
        }
        .background {
            RadialGradient(colors: [Color.lingHolo.opacity(0.16), Color.clear], center: .top, startRadius: 60, endRadius: 620)
        }
    }
}

struct HoloCoreView: View {
    let isListening: Bool

    var body: some View {
        let pulse = isListening ? 1.04 : 1.0

        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .stroke(Color.lingHolo.opacity(0.13 - Double(index) * 0.018), lineWidth: 1)
                    .frame(width: 92 + CGFloat(index * 31), height: 92 + CGFloat(index * 31))
                    .rotationEffect(.degrees(Double(index) * 18))
            }

            Circle()
                .stroke(AngularGradient(colors: [Color.lingHolo, Color.lingHoloAlt, Color.lingHolo.opacity(0.35), Color.lingHolo], center: .center), lineWidth: 2)
                .frame(width: 124, height: 124)
                .scaleEffect(pulse)
                .shadow(color: Color.lingHolo.opacity(isListening ? 0.55 : 0.32), radius: isListening ? 32 : 20)

            Circle()
                .fill(RadialGradient(colors: [Color.lingHolo.opacity(0.34), Color.lingHoloAlt.opacity(0.12), Color.clear], center: .center, startRadius: 4, endRadius: 88))
                .frame(width: 136, height: 136)

            VStack(spacing: 5) {
                Image(systemName: isListening ? "waveform" : "sparkles")
                    .font(.system(size: 30, weight: .bold))
                Text("灵枢")
                    .font(.system(size: 22, weight: .semibold))
                Text(isListening ? "VOICE LINK" : "CORE ONLINE")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .opacity(0.72)
            }
            .foregroundStyle(.white)

            HoloOrbitBadge(title: "规划", angle: 0, radius: 92, color: .teal)
            HoloOrbitBadge(title: "审议", angle: 72, radius: 92, color: .red)
            HoloOrbitBadge(title: "调度", angle: 144, radius: 92, color: .cyan)
            HoloOrbitBadge(title: "执行", angle: 216, radius: 92, color: .orange)
            HoloOrbitBadge(title: "验证", angle: 288, radius: 92, color: .green)
        }
    }
}

struct HoloOrbitBadge: View {
    let title: String
    let angle: Double
    let radius: CGFloat
    let color: Color

    var body: some View {
        let radians = angle / 180 * Double.pi
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.28), in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.52), lineWidth: 1)
            }
            .offset(x: CGFloat(cos(radians)) * radius, y: CGFloat(sin(radians)) * radius * 0.52)
    }
}

struct HoloStatusDot: View {
    let active: Bool

    var body: some View {
        Circle()
            .fill(active ? Color.red : Color.lingHolo)
            .frame(width: 8, height: 8)
            .shadow(color: active ? Color.red.opacity(0.8) : Color.lingHolo.opacity(0.8), radius: 8)
    }
}

struct HoloMetricRow: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = .lingHolo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: 190, alignment: .trailing)
        }
    }
}

struct MissionStatusPanelView: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "point.3.connected.trianglepath.dotted", title: "调用链", subtitle: state.callChainSubtitle)

                VStack(alignment: .leading, spacing: 8) {
                    Text(state.missionTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(state.missionStatus)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    HoloMetricRow(label: "主线程", value: state.mainThreadHeartbeatText, icon: "bolt.horizontal.circle", color: .cyan)
                    HoloMetricRow(label: "主线程状态", value: state.mainRemoteConnectionStatus, icon: "circle.fill", color: state.mainRemoteConnectionIndicatorColor)
                    HoloMetricRow(label: "在线 agent", value: "\(state.agentRuntimeCounts.online)", icon: "antenna.radiowaves.left.and.right", color: .green)
                    HoloMetricRow(label: "运行 agent", value: "\(state.agentRuntimeCounts.running)", icon: "play.circle", color: .lingHolo)
                    HoloMetricRow(label: "待启动", value: "\(state.agentRuntimeCounts.pendingStart)", icon: "pause.circle", color: .white.opacity(0.72))
                    HoloMetricRow(label: "外部 agent", value: "\(state.externalAgentRegistrySnapshot.enabled)/\(state.externalAgentRegistrySnapshot.registered)", icon: "network", color: .cyan)
                    HoloMetricRow(label: "运行期", value: state.runtimePhase.rawValue, icon: state.runtimePhase.icon, color: state.runtimePhase.color)
                    HoloMetricRow(label: "任务线程", value: state.taskQueueSummary, icon: "square.stack.3d.up", color: .purple)
                    HoloMetricRow(label: "心跳空闲", value: state.modelHeartbeatIdleText, icon: "waveform.path.ecg", color: state.hasActiveModelCall ? .green : .lingFaint)
                    HoloMetricRow(label: "执行线程", value: "\(state.activeWorkerCount)", icon: "cpu")
                    HoloMetricRow(label: "监工线程", value: "\(state.activeSupervisorCount)", icon: "eye")
                    HoloMetricRow(label: "巡检轮次", value: "\(state.supervisionTick)", icon: "timer")
                }

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Agent 状态")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("调用链状态正在初始化。")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    Text("最近巡检")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    if state.supervisorEvents.isEmpty {
                        Text("暂无巡检事件，等待灵枢发令。")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.50))
                    } else {
                        ForEach(state.supervisorEvents.prefix(3)) { event in
                            SupervisorChainEventRow(event: event)
                        }
                    }
                }

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    Text("模型访问")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    HoloMetricRow(label: "服务商", value: state.modelProvider, icon: "server.rack")
                    HoloMetricRow(label: "模型", value: state.modelName, icon: "brain")
                    HoloMetricRow(label: "连接", value: state.modelConnectionState, icon: "link", color: state.isModelConnected ? .lingHolo : .orange)
                    HoloMetricRow(label: "执行策略", value: state.requireHumanApproval ? "人工确认" : "自动执行", icon: "hand.raised")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.16))
        }
    }
}

struct AgentCallChainRow: View {
    let index: Int
    let agent: LingShuAgent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(agent.state.color.opacity(agent.state == .waiting ? 0.10 : 0.22))
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(agent.state.color)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(agent.shortName, systemImage: agent.symbol)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.90))
                        .lineLimit(1)
                    Spacer()
                    Text(agent.mode.rawValue)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(agent.state.color)
                    Text(agent.cadence)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                }

                Text(agent.focus)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(2)

                if agent.lastFinding != "尚未巡检" {
                    Text(agent.lastFinding)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                }

                ProgressView(value: agent.load)
                    .tint(agent.color)
                    .scaleEffect(x: 1, y: 0.55, anchor: .center)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}

struct SupervisorChainEventRow: View {
    let event: SupervisorEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("巡检\(event.tick)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(event.severity.eventColor)
                Text("\(event.agent) / \(event.title)")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
            Text(event.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}
