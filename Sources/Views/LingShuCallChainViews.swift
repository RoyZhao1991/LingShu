import SwiftUI

/// 右侧栏:**绑当前这轮的真实进展**(正在执行的 runbook 步 / 正在调的工具 / 执行轨迹尾部 / 已用时),
/// 不再堆静态聚合遥测(在线 agent/监工线程/巡检轮次等伪指标已删,计划 §2)。真空闲给有意义的空态。
struct LingShuCallChainPanel: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                SectionHeader(icon: "point.3.connected.trianglepath.dotted", title: state.loc("本轮进展", "Live Progress"), subtitle: state.hasLiveProgress ? state.loc("实时执行中", "Running") : state.loc("空闲待命", "Idle"))

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
                    notConnectedNotice
                } else if state.hasLiveProgress {
                    liveProgressBody
                } else {
                    idleNotice
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

    private var notConnectedNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.loc("主通道未接入", "Model channel offline"), systemImage: "link.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.92))
            Text(state.loc("主通道就绪后这里会实时显示灵枢正在做什么；未接入时不展示任何虚假进展。", "Once the model channel is ready, this shows what \(state.appName) is doing in real time; nothing fake is shown while offline."))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 真有活在跑:中枢状态 + 已用时 + 当前动作 + 独立运行 runbook 步 + 计划进度 + 执行轨迹尾部(全真实)。
    private var liveProgressBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HoloMetricRow(label: state.loc("中枢状态", "Core state"), value: state.coreStateDisplay, icon: state.coreState.icon, color: state.coreState.color)
                if let elapsed = state.currentRoundElapsed {
                    HoloMetricRow(label: state.loc("已用时", "Elapsed"), value: elapsed, icon: "timer", color: .lingHolo)
                }
                if let tool = state.currentToolDisplay {
                    HoloMetricRow(label: state.loc("当前动作", "Action"), value: tool, icon: "cursorarrow.motionlines", color: .cyan)
                }
                if state.autonomousRun.isActive {
                    HoloMetricRow(label: state.loc("权限", "Permission"), value: state.loc(state.autonomousRun.permissionLevel.rawValue, state.autonomousRun.permissionLevel.englishName), icon: "lock.shield", color: .orange)
                }
                if let progress = state.currentPlanProgress {
                    HoloMetricRow(label: state.loc("计划", "Plan"), value: state.loc("\(progress.done)/\(progress.total) 步完成", "\(progress.done)/\(progress.total) done"), icon: "checklist", color: .green)
                }
            }

            if let running = state.autonomousRunningStep {
                LingShuDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.loc("当前 Runbook 步", "Current step"))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(format: "%02d/%02d", running.index, running.total))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.orange)
                            .frame(width: 48, height: 24)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(running.step.title)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(running.step.detail)
                                .font(.system(size: 10.8, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                    }
                }
            }

            LingShuDivider()

            VStack(alignment: .leading, spacing: 9) {
                Text(state.loc("执行轨迹", "Execution trace"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                let messages = state.recentExecutionMessages
                if messages.isEmpty {
                    Text(state.coreState == .thinking ? state.loc("灵枢正在思考，尚未发起动作。", "\(state.appName) is thinking; no action yet.") : state.loc("本轮刚开始，等待第一步动作。", "Just started; waiting for the first action."))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    ForEach(messages) { message in
                        LiveExecutionStepRow(message: message)
                    }
                }
            }
        }
    }

    /// 真空闲:有意义的空态(不是一排 0/待命),引导给目标。
    private var idleNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.lingHolo.opacity(0.8))
                Text(state.loc("空闲中 · 随时待命", "Idle · ready"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(state.loc("当前没有进行中的任务。在对话里发指令，或让灵枢上岗成为常驻灵枢——这里会实时显示它正在执行的步骤、调用的工具与执行轨迹。", "No active task. Send a command in chat, or have \(state.appName) go on duty — its live steps, tools and trace will show here."))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            HoloMetricRow(label: state.loc("主记忆", "Memory"), value: state.mainMemoryStatus, icon: "memorychip", color: .cyan)
            HoloMetricRow(label: state.loc("冷备库", "Cold store"), value: state.coldMemoryStatus, icon: "externaldrive", color: .orange)
        }
    }
}

/// 执行轨迹一行:按结构化 detail 取图标/着色,渲染当前记录尾部的工具调用/结果/文件改动(真实活动)。
struct LiveExecutionStepRow: View {
    let message: LingShuTaskExecutionMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            Text(message.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch message.detail {
        case .toolCall: return "cursorarrow.motionlines"
        case .toolResult(_, let success, _): return success ? "checkmark.circle" : "exclamationmark.triangle"
        case .fileEdit: return "doc.badge.gearshape"
        case .none: return "circlebadge"
        }
    }

    private var tint: Color {
        switch message.detail {
        case .toolCall: return .cyan
        case .toolResult(_, let success, _): return success ? .green : .orange
        case .fileEdit: return .lingHolo
        case .none: return .white.opacity(0.5)
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
