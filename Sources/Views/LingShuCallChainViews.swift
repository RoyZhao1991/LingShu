import SwiftUI

/// 右侧栏:**绑当前这轮的真实进展**(正在执行的 runbook 步 / 正在调的工具 / 执行轨迹尾部 / 已用时),
/// 不再堆静态聚合遥测(在线 agent/监工线程/巡检轮次等伪指标已删,计划 §2)。真空闲给有意义的空态。
struct LingShuCallChainPanel: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                SectionHeader(icon: "point.3.connected.trianglepath.dotted", title: "本轮进展", subtitle: state.hasLiveProgress ? "实时执行中" : "空闲待命")

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
            Label("主通道未接入", systemImage: "link.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.92))
            Text("主通道就绪后这里会实时显示灵枢正在做什么；未接入时不展示任何虚假进展。")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 真有活在跑:中枢状态 + 已用时 + 当前动作 + 独立运行 runbook 步 + 计划进度 + 执行轨迹尾部(全真实)。
    private var liveProgressBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HoloMetricRow(label: "中枢状态", value: state.coreStateDisplay, icon: state.coreState.icon, color: state.coreState.color)
                if let elapsed = state.currentRoundElapsed {
                    HoloMetricRow(label: "已用时", value: elapsed, icon: "timer", color: .lingHolo)
                }
                if let tool = state.currentToolDisplay {
                    HoloMetricRow(label: "当前动作", value: tool, icon: "cursorarrow.motionlines", color: .cyan)
                }
                if state.autonomousRun.isActive {
                    HoloMetricRow(label: "权限", value: state.autonomousRun.permissionLevel.rawValue, icon: "lock.shield", color: .orange)
                }
                if let progress = state.currentPlanProgress {
                    HoloMetricRow(label: "计划", value: "\(progress.done)/\(progress.total) 步完成", icon: "checklist", color: .green)
                }
            }

            if let running = state.autonomousRunningStep {
                LingShuDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前 Runbook 步")
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
                Text("执行轨迹")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                let messages = state.recentExecutionMessages
                if messages.isEmpty {
                    Text(state.coreState == .thinking ? "灵枢正在思考，尚未发起动作。" : "本轮刚开始，等待第一步动作。")
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
                Text("空闲中 · 随时待命")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text("当前没有进行中的任务。在对话里发指令，或到左侧「独立运行」给一个目标并启动——这里会实时显示它正在执行的步骤、调用的工具与执行轨迹。")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            HoloMetricRow(label: "主记忆", value: state.mainMemoryStatus, icon: "memorychip", color: .cyan)
            HoloMetricRow(label: "冷备库", value: state.coldMemoryStatus, icon: "externaldrive", color: .orange)
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
