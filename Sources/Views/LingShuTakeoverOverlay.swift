import SwiftUI

/// 完全接管态遮罩（模块 1）：常驻数字人在岗（完全接管）时，在整窗叠加一层**接管态指示**——
/// 屏幕边缘辉光（提示"灵枢在接管"，不拦输入）+ 顶部悬浮控制条（当前在做什么 + 周期感知态势 +
/// 暂停/继续 + **一键停止并夺回**）。
///
/// 取向（务实）：macOS 无官方独占输入 API，**不做硬屏蔽**（用户随时能动手）；
/// 遮罩只负责「让接管态可见 + 随手能夺回」，边框辉光与背景 `allowsHitTesting(false)` 绝不挡用户操作，
/// 只有控制条本身可点。
struct LingShuTakeoverOverlay: View {
    @ObservedObject var state: LingShuState

    var body: some View {
        if state.isStandingPersonOnDuty {
            ZStack(alignment: .top) {
                edgeGlow
                controlBar
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: state.autonomousRun.phase)
        }
    }

    /// 屏幕边缘辉光：接管态的"氛围遮罩"，不拦任何输入。
    private var edgeGlow: some View {
        Rectangle()
            .strokeBorder(
                LinearGradient(
                    colors: [Color.lingHolo.opacity(0.85), Color.lingHolo.opacity(0.3), Color.lingHolo.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 3
            )
            .shadow(color: Color.lingHolo.opacity(0.35), radius: 10)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            pulsingDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("灵枢接管中")
                        .font(.system(size: 13.5, weight: .heavy))
                        .foregroundStyle(Color.lingHolo)
                    Text("LINGSHU · AUTONOMOUS")
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.lingHolo.opacity(0.85))
                }
                Text(currentActivityLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                if !state.perceptionDigest.isEmpty {
                    Label(state.perceptionDigest, systemImage: "eye")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.lingHolo.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            autoReactToggle
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 760)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private var pulsingDot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: state.autonomousRun.phase != .running)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let on = state.autonomousRun.phase == .running
            let pulse = on ? (0.45 + 0.55 * (0.5 + 0.5 * sin(t * 3.2))) : 0.5
            Circle()
                .fill(state.autonomousRun.phase == .paused ? Color.lingHoloAlt : Color.lingHolo)
                .frame(width: 11, height: 11)
                .shadow(color: (state.autonomousRun.phase == .paused ? Color.lingHoloAlt : Color.lingHolo).opacity(pulse), radius: 6)
                .opacity(0.55 + 0.45 * pulse)
        }
        .frame(width: 12, height: 12)
    }

    private var currentActivityLine: String {
        let status = state.missionStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        switch state.autonomousRun.phase {
        case .paused: return "已暂停 · 等待继续或夺回"
        default: return "在岗待命 · 直接对话或发指令即可"
        }
    }

    /// 自主反应「武装」开关：开 = 环境事件可唤醒大脑自主处理（需感知系统声音）；关 = 安全默认。
    private var autoReactToggle: some View {
        Button {
            state.autonomousAutoReactArmed.toggle()
        } label: {
            Label(state.autonomousAutoReactArmed ? "自主反应·开" : "自主反应·关",
                  systemImage: state.autonomousAutoReactArmed ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(state.autonomousAutoReactArmed ? Color.lingHolo : .white.opacity(0.5))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background((state.autonomousAutoReactArmed ? Color.lingHolo : Color.white).opacity(0.1),
                           in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("开启后，环境变化（系统声音出现、前台界面切换等）会把观察喂给灵枢、由它综合评判要不要处理；关闭则只持续更新态势、不擅自行动。")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            switch state.autonomousRun.phase {
            case .running:
                pillButton("暂停", icon: "pause.fill", tint: .lingHoloAlt) { state.pauseAutonomousRun() }
            case .paused:
                pillButton("继续", icon: "play.fill", tint: .lingHolo) { state.resumeAutonomousRun() }
            default:
                EmptyView()
            }
            // 一键停止并夺回控制——任何在岗相位都可用，这是接管态的安全闸。
            pillButton("停止并夺回", icon: "hand.raised.fill", tint: .red) { state.stopAutonomousRun() }
        }
    }

    private func pillButton(_ label: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.45), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
