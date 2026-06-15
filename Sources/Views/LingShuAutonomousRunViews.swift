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
        let objectiveEmpty = state.autonomousObjectiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 14) {
            Text("给灵枢一个目标(可上传文件 + 写指令),它会先做环境检测、自检和动态规划；授权后自主推进。独立运行=授予完整电脑控制权,推进中不再要授权(删/改系统级敏感文件除外)。")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            objectiveInput

            if !state.pendingAttachments.isEmpty {
                LingShuAttachmentTray(state: state)
            }

            HStack(spacing: 10) {
                Button {
                    state.presentAttachmentPicker()
                } label: {
                    Label("上传文件", systemImage: "paperclip")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.lingHolo)
                        .frame(height: 30)
                        .padding(.horizontal, 12)
                        .background(Color.lingHolo.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.lingHolo.opacity(0.25), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                Spacer()
            }

            permissionPicker

            // 贾维斯式启动按钮:大、居中、科技感(呼吸弧环,TimelineView 自驱不拖累状态)。空目标禁用并提示。
            JarvisLaunchButton(
                title: objectiveEmpty ? "请先填写目标" : "启动独立运行",
                subtitle: objectiveEmpty ? "AUTONOMOUS · 需要目标" : "AUTONOMOUS · 自主推进",
                isEnabled: !objectiveEmpty
            ) {
                state.prepareAutonomousRun(objective: state.autonomousObjectiveDraft)
            }
        }
    }

    /// 独立运行专门目标输入框(多行,带占位提示);与对话主输入框解耦。
    private var objectiveInput: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.lingHolo.opacity(0.18), lineWidth: 1) }
            if state.autonomousObjectiveDraft.isEmpty {
                Text("例:把桌面上的季度数据整理成一份汇报 PPT 并自检到达标")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $state.autonomousObjectiveDraft)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(minHeight: 64, maxHeight: 110)
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
        // 左对齐到标题同一起始 x:隐藏空 label(否则段控会被 label 占位顶偏)+ 整条铺满前缘(计划 §6)。
        Picker("", selection: $state.autonomousPermissionLevel) {
            ForEach(LingShuAutonomousPermissionLevel.allCases) { level in
                Text(level.rawValue).tag(level)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 贾维斯式独立运行启动按钮——大、居中、科技感:旋转弧环 + 呼吸(只在左侧小反应堆里动)。
/// **性能(计划 §7)**:按钮主体(渐变/边框/阴影/文字)是**静态**的,不进 TimelineView;只有左侧轻量 `JarvisReactor`
/// 自带一个低帧(20fps)TimelineView 动它那一小块——避免每帧重渲整颗按钮(渐变+扫光+阴影脉动)拖卡。
/// 已**去掉扫光与阴影脉动**,保留呼吸 + 弧环。`isEnabled=false`(无目标)时置灰、停动、点按无效。
struct JarvisLaunchButton: View {
    let title: String
    let subtitle: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: { if isEnabled { action() } }) {
            HStack(spacing: 14) {
                JarvisReactor(animating: isEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Color.lingVoid)
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.lingVoid.opacity(0.6))
                        .tracking(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color.lingVoid.opacity(0.75))
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                LinearGradient(colors: isEnabled ? [Color.lingHolo, Color.lingHoloAlt] : [Color.gray.opacity(0.45), Color.gray.opacity(0.32)],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: (isEnabled ? Color.lingHolo : Color.clear).opacity(0.4), radius: hovering ? 22 : 16, y: 4)
            .scaleEffect(pressed ? 0.97 : (hovering ? 1.015 : 1.0))
            .opacity(isEnabled ? 1.0 : 0.85)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = isEnabled && $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
        .frame(height: 64)
    }
}

/// 左侧"弧反应堆":同心旋转弧 + 中心电源图标(贾维斯启动键意象)。自带低帧 TimelineView,**只动这一小块**。
private struct JarvisReactor: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animating)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = animating ? (0.5 + 0.5 * sin(t * 1.6)) : 0.5
            let spin = Angle(degrees: animating ? (t * 60).truncatingRemainder(dividingBy: 360) : 0)
            ZStack {
                Circle().stroke(Color.lingVoid.opacity(0.30), lineWidth: 2).frame(width: 38, height: 38)
                Circle().trim(from: 0, to: 0.28)
                    .stroke(Color.lingVoid.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 38, height: 38)
                    .rotationEffect(spin)
                Circle().trim(from: 0.5, to: 0.7)
                    .stroke(Color.lingVoid.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 28, height: 28)
                    .rotationEffect(-spin * 1.4)
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color.lingVoid)
                    .opacity(0.75 + 0.25 * breathe)
            }
            .frame(width: 40, height: 40)
        }
        .frame(width: 40, height: 40)
    }
}
