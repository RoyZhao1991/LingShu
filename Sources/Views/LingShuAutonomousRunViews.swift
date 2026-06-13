import SwiftUI

struct LingShuAutonomousRunPanel: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if state.autonomousRun.phase == .idle {
                idleBody
            } else {
                activeBody
            }
        }
        .padding(16)
        .lingShuHUDPanel(accent: state.autonomousRun.isActive ? .orange : .lingHolo, cornerLength: 12, fillOpacity: 0.035)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(state.autonomousRun.isActive ? .orange : .lingHolo)
                .frame(width: 30, height: 30)
                .background((state.autonomousRun.isActive ? Color.orange : Color.lingHolo).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("独立运行模式")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("目标驱动 · 动态 runbook · 环境自检 · 人工接管")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Text(state.autonomousRun.phase.rawValue)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(state.autonomousRun.isActive ? .orange : .white.opacity(0.54))
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把当前输入框内容作为目标，先做环境检测、自检和动态规划；授权后再开始自主推进。")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                permissionPicker
                Button {
                    state.prepareAutonomousRun()
                } label: {
                    Label("准备独立运行", systemImage: "sparkles")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color.lingVoid)
                        .frame(height: 32)
                        .padding(.horizontal, 14)
                        .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var activeBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    metric(label: "目标", value: state.autonomousRun.objective.isEmpty ? "等待目标" : state.autonomousRun.objective, icon: "scope")
                    metric(label: "权限", value: state.autonomousRun.permissionLevel.rawValue, icon: "lock.shield")
                    metric(label: "状态", value: state.autonomousRun.statusLine, icon: "waveform.path.ecg")
                }
                Spacer(minLength: 12)
                controls
            }

            if let environment = state.autonomousRun.environment {
                compactChecks(title: "环境检测", report: environment.items)
            }

            if let selfCheck = state.autonomousRun.selfCheck {
                compactChecks(title: "自检", report: selfCheck.items)
            }

            if let runbook = state.autonomousRun.runbook {
                runbookView(runbook)
            }
        }
    }

    private var permissionPicker: some View {
        Picker("", selection: $state.autonomousPermissionLevel) {
            ForEach(LingShuAutonomousPermissionLevel.allCases) { level in
                Text(level.rawValue).tag(level)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .help(state.autonomousPermissionLevel.detail)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            switch state.autonomousRun.phase {
            case .ready:
                compactButton("授权执行", icon: "play.fill", tint: .lingHolo) { state.authorizeAutonomousRun() }
            case .running:
                compactButton("暂停", icon: "pause.fill", tint: .orange) { state.pauseAutonomousRun() }
            case .paused:
                compactButton("继续", icon: "play.fill", tint: .lingHolo) { state.resumeAutonomousRun() }
            case .blocked:
                compactButton("重检", icon: "arrow.clockwise", tint: .orange) { state.prepareAutonomousRun(objective: state.autonomousRun.objective) }
            case .idle, .probing, .planning, .completed:
                compactButton("重建", icon: "sparkles", tint: .lingHolo) { state.prepareAutonomousRun(objective: state.autonomousRun.objective) }
            }
            compactButton("停止", icon: "stop.fill", tint: .red) { state.stopAutonomousRun() }
        }
    }

    private func metric(label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.lingHolo)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
        }
    }

    private func compactChecks(title: String, report: [LingShuAutonomousCheckItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                ForEach(report) { item in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(color(for: item.level))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.82))
                            Text(item.detail)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func runbookView(_ runbook: LingShuAutonomousRunbook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("动态 Runbook")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(runbook.capabilityHints.joined(separator: " / "))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHolo.opacity(0.8))
                    .lineLimit(1)
            }

            ForEach(Array(runbook.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(color(for: step.status))
                        .frame(width: 30, height: 24)
                        .background(color(for: step.status).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(step.title)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(step.owner)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(color(for: step.status))
                        }
                        Text(step.detail)
                            .font(.system(size: 10.8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(step.status.rawValue)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func compactButton(_ label: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(height: 30)
                .padding(.horizontal, 10)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func color(for level: LingShuAutonomousCheckLevel) -> Color {
        switch level {
        case .pass: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    private func color(for status: LingShuAutonomousRunbookStepStatus) -> Color {
        switch status {
        case .waiting: .white.opacity(0.42)
        case .running: .orange
        case .completed: .green
        case .blocked: .red
        }
    }
}
