import SwiftUI

/// 极简 AI 模式 = 一个小小的常浮通话窗（豆包视频通话式连续对话）：进入即自动开始听，
/// VAD 静音断句自动提交，灵枢自动应答、应答完自动接着听，全程免手。
/// 窗口里只有三样东西：你的摄像头画面、两条对话音轨（你 + 灵枢，真实电平驱动）、挂断/静音。
struct LingShuMinimalVoiceView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @StateObject private var call = LingShuVoiceCallController()

    var body: some View {
        ZStack {
            Color.lingVoid.ignoresSafeArea()
            RadialGradient(
                colors: [stateColor.opacity(0.14), .clear],
                center: .init(x: 0.5, y: 0.3), startRadius: 10, endRadius: 360
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: stateColor)

            VStack(spacing: 0) {
                header
                selfCamera
                    .padding(.top, 10)
                waveforms
                    .padding(.top, 14)
                Spacer(minLength: 10)
                controls.padding(.bottom, 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
        .onAppear {
            call.start(state: state, voice: voice, perceptionGateway: perceptionGateway)
            if !vision.isCameraRunning {
                LingShuPerceptionActions.toggleVision(state: state, vision: vision)
            }
        }
        .onDisappear {
            call.stop()
            if vision.isCameraRunning {
                vision.stopCamera()
            }
        }
    }

    // MARK: - 顶部状态

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                    .shadow(color: stateColor.opacity(0.8), radius: 4)
                Text(call.phase.caption)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(stateColor)
                    .contentTransition(.opacity)
            }
            Spacer()
            Text("实时通话")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - 自拍摄像头

    private var selfCamera: some View {
        ZStack {
            if vision.isCameraRunning {
                CameraPreviewView(session: vision.captureSession)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
                    .overlay {
                        VStack(spacing: 7) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("摄像头关闭")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 196)
        .overlay { LingShuHUDCorners(accent: stateColor.opacity(0.5), cornerLength: 12) }
    }

    // MARK: - 双波形

    private var waveforms: some View {
        VStack(spacing: 10) {
            waveformRow(label: "你", color: .lingHoloAlt, level: { voice.inputLevel }, active: { voice.isRecording })
            waveformRow(label: "灵枢", color: .lingHolo, level: { voice.outputLevel }, active: { voice.isSpeaking })
        }
    }

    private func waveformRow(label: String, color: Color, level: @escaping () -> Float, active: @escaping () -> Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(color.opacity(0.9))
                .frame(width: 34, alignment: .leading)
            LingShuLiveWaveform(color: color, level: level, active: active)
                .frame(height: 44)
        }
    }

    // MARK: - 控制

    private var controls: some View {
        HStack(spacing: 20) {
            // 摄像头开关
            circleButton(
                icon: vision.isCameraRunning ? "video.fill" : "video.slash.fill",
                bg: vision.isCameraRunning ? Color.white.opacity(0.12) : Color.white.opacity(0.06),
                fg: vision.isCameraRunning ? .white : .white.opacity(0.6),
                size: 44
            ) {
                LingShuPerceptionActions.toggleVision(state: state, vision: vision)
            }
            // 挂断
            circleButton(icon: "phone.down.fill", bg: Color.red.opacity(0.9), fg: .white, size: 56) {
                state.isMinimalVoiceMode = false
            }
            // 静音麦克风（暂停/恢复连续监听）
            circleButton(
                icon: voice.isRecording ? "mic.fill" : "mic.slash.fill",
                bg: voice.isRecording ? Color.lingHolo : Color.white.opacity(0.06),
                fg: voice.isRecording ? Color.lingVoid : .white.opacity(0.6),
                size: 44
            ) {
                if call.isActive {
                    call.stop()
                } else {
                    call.start(state: state, voice: voice, perceptionGateway: perceptionGateway)
                }
            }
        }
    }

    private func circleButton(icon: String, bg: Color, fg: Color, size: CGFloat = 58, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(fg)
                .frame(width: size, height: size)
                .background(bg, in: Circle())
                .shadow(color: bg.opacity(0.5), radius: 10)
        }
        .buttonStyle(.plain)
    }

    private var stateColor: Color { state.coreState.color }
}

/// 实时音频波形：滚动的电平历史画成对称柱状波形，level 0...1 实时驱动。
struct LingShuLiveWaveform: View {
    var color: Color
    var level: () -> Float
    var active: () -> Bool

    @State private var history: [CGFloat] = Array(repeating: 0, count: 72)
    @State private var isActiveNow = false

    var body: some View {
        Canvas { context, size in
            let count = history.count
            let gap: CGFloat = 3
            let barWidth = max(1.5, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let midY = size.height / 2
            for (index, value) in history.enumerated() {
                let x = CGFloat(index) * (barWidth + gap)
                let h = max(2, value * size.height)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                let freshness = CGFloat(index) / CGFloat(count)
                let opacity = 0.2 + 0.8 * freshness
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color.opacity(isActiveNow ? opacity : opacity * 0.4))
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
        .overlay { LingShuHUDCorners(accent: color.opacity(0.4), cornerLength: 10) }
        .task {
            // 在渲染之外、约 30fps 读取实时电平并推进历史，得到滚动波形。
            while !Task.isCancelled {
                let active = self.active()
                isActiveNow = active
                var next = history
                next.removeFirst()
                let jitter = active ? CGFloat.random(in: 0.8...1.2) : 1
                next.append(min(1, CGFloat(self.level()) * jitter))
                history = next
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }
}
