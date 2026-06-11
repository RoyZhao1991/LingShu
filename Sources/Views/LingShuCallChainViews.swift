import SwiftUI

struct LingShuCallChainPanel: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
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

                LingShuDivider()

                if !state.isModelConnected {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("主通道未接入", systemImage: "link.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.orange.opacity(0.92))
                        Text("主通道就绪后，我会按任务需要动态唤起相关能力节点；未接入时不会展示虚假的调用链。")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
	                    VStack(alignment: .leading, spacing: 9) {
	                        HoloMetricRow(label: "中枢状态", value: state.coreStateDisplay, icon: state.coreState.icon, color: state.coreState.color)
	                        HoloMetricRow(label: "主线程", value: state.mainThreadHeartbeatText, icon: "bolt.horizontal.circle", color: .cyan)
                        HoloMetricRow(label: "主线程状态", value: state.mainRemoteConnectionStatus, icon: "circle.fill", color: state.mainRemoteConnectionIndicatorColor)
                        HoloMetricRow(label: "在线 agent", value: "\(state.agentRuntimeCounts.online)", icon: "antenna.radiowaves.left.and.right", color: .green)
                        HoloMetricRow(label: "运行 agent", value: "\(state.agentRuntimeCounts.running)", icon: "play.circle", color: .lingHolo)
                        HoloMetricRow(label: "待启动", value: "\(state.agentRuntimeCounts.pendingStart)", icon: "pause.circle", color: .white.opacity(0.72))
                        HoloMetricRow(label: "外部 agent", value: "\(state.externalAgentRegistrySnapshot.enabled)/\(state.externalAgentRegistrySnapshot.registered)", icon: "network", color: .cyan)
                        HoloMetricRow(label: "思考耗时", value: state.thinkingElapsedText, icon: "brain.head.profile", color: .cyan)
	                        HoloMetricRow(label: "执行耗时", value: state.executionElapsedText, icon: "timer", color: .lingHolo)
                        HoloMetricRow(label: "心跳空闲", value: state.modelHeartbeatIdleText, icon: "waveform.path.ecg", color: state.hasActiveModelCall ? .green : .lingFaint)
                        HoloMetricRow(label: "运行期", value: state.runtimePhase.rawValue, icon: state.runtimePhase.icon, color: state.runtimePhase.color)
                        HoloMetricRow(label: "任务线程", value: state.taskQueueSummary, icon: "square.stack.3d.up", color: .purple)
                        HoloMetricRow(label: "主记忆", value: state.mainMemoryStatus, icon: "memorychip", color: .cyan)
                        HoloMetricRow(label: "冷备库", value: state.coldMemoryStatus, icon: "externaldrive", color: .orange)
                        HoloMetricRow(label: "执行线程", value: "\(state.activeWorkerCount)", icon: "cpu")
                        HoloMetricRow(label: "监工线程", value: "\(state.activeSupervisorCount)", icon: "eye")
	                        HoloMetricRow(label: "巡检轮次", value: "\(state.supervisionTick)", icon: "timer")
	                    }

	                    LingShuDivider()

                    if state.shouldShowTaskRuntime {
                        TaskRuntimePanelView(runtime: state.taskRuntime)

                        LingShuDivider()
                    }

                    if !state.visibleTaskThreads.isEmpty {
                        TaskThreadQueuePanelView(threads: state.visibleTaskThreads)

                        LingShuDivider()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("本次调用")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)

                        if state.callChainAgents.isEmpty {
                            Text(state.coreState == .thinking ? "灵枢正在思考，尚未分派能力节点。" : "暂无 agent 参与。本轮可能由灵枢直接处理。")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.50))
                        } else {
                            ForEach(Array(state.callChainAgents.enumerated()), id: \.element.id) { index, agent in
                                LingShuAgentStatusRow(index: index, agent: agent)
                            }
                        }
                    }
                }

                LingShuDivider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("最近巡检")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    if state.supervisorEvents.isEmpty {
                        Text("暂无巡检事件，等待灵枢发令。")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.50))
                    } else {
                        ForEach(state.supervisorEvents.prefix(4)) { event in
                            SupervisorChainEventRow(event: event)
                        }
                    }
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

struct TaskThreadQueuePanelView: View {
    let threads: [LingShuTaskThread]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                    .frame(width: 24, height: 24)
                    .background(Color.lingHolo.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("任务队列")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("同线程串行，异线程隔离并行")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color.lingHolo.opacity(0.82))
                }
            }

            ForEach(threads) { thread in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(thread.hasRunningSegment ? Color.lingHolo : Color.white.opacity(0.38))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(thread.displayTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                        Text("运行 \(thread.runningSegmentCount) / 排队 \(thread.queuedSegmentCount)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.52))
                    }

                    Spacer()

                    Text(thread.status.rawValue)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(thread.hasRunningSegment ? Color.lingHolo : .white.opacity(0.50))
                }
                .padding(.vertical, 5)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.12))
        }
    }
}

struct TaskRuntimePanelView: View {
    let runtime: TaskRuntimeSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: runtime.stage.icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(runtime.stage.color)
                    .frame(width: 24, height: 24)
                    .background(runtime.stage.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("任务运行时")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(runtime.stage.rawValue)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(runtime.stage.color.opacity(0.88))
                }

                Spacer()

                Text(runtime.taskID)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }

            Text(runtime.summary)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                HoloMetricRow(label: "当前动作", value: runtime.currentAction, icon: "cursorarrow.motionlines", color: runtime.stage.color)
                HoloMetricRow(label: "执行器", value: runtime.executionEngine, icon: "cpu", color: .cyan)
                HoloMetricRow(label: "权限边界", value: runtime.permissionBoundary, icon: "lock.shield", color: .orange)
                HoloMetricRow(label: "记忆", value: runtime.memoryStatus, icon: "brain", color: .purple)
                HoloMetricRow(label: "Review", value: runtime.reviewGate, icon: "checkmark.seal", color: .green)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(runtime.checks) { check in
                    TaskRuntimeCheckRow(check: check)
                }
            }
        }
    }
}

struct TaskRuntimeCheckRow: View {
    let check: TaskRuntimeCheck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.state.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(check.state.color)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                Text(check.detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(2)
            }
        }
    }
}

struct LingShuAgentStatusRow: View {
    let index: Int
    let agent: LingShuAgent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(agent.state.color)
                .frame(width: 28, height: 24)
                .background(agent.state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(agent.shortName)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.90))
                    Text(agent.mode.rawValue)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(agent.mode.color)
                    Spacer()
                    Text(agent.cadence)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                }

                Text(agent.focus)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(2)

                if agent.lastFinding != "尚未巡检" {
                    Text(agent.lastFinding)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(2)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(agent.color.opacity(0.78))
                            .frame(width: max(8, proxy.size.width * agent.load))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}

struct LingShuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 1)
    }
}
