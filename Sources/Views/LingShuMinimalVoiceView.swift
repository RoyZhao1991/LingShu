import SwiftUI

/// 极简 AI 模式：全屏，只有输入波形（你）+ 输出波形（灵枢），纯语音对话。
/// 输入波形由真实麦克风电平驱动，输出波形由真实 TTS 音量计驱动。
struct LingShuMinimalVoiceView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        ZStack {
            Color.lingVoid.ignoresSafeArea()
            RadialGradient(
                colors: [stateColor.opacity(0.12), .clear],
                center: .center, startRadius: 20, endRadius: 520
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: stateColor)

            VStack(spacing: 0) {
                header

                Spacer()

                // 输入波形（你）
                waveformBlock(
                    label: "你",
                    color: .lingHoloAlt,
                    level: voice.inputLevel,
                    active: voice.isRecording,
                    caption: voice.isRecording ? "正在聆听" : "点击麦克风开始说话"
                )

                Spacer().frame(height: 28)

                // 输出波形（灵枢）
                waveformBlock(
                    label: "灵枢",
                    color: .lingHolo,
                    level: voice.outputLevel,
                    active: voice.isSpeaking,
                    caption: captionForOutput
                )

                Spacer()

                micButton
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 48)
            .padding(.top, 24)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                    .shadow(color: stateColor.opacity(0.8), radius: 4)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(state.coreStateDisplay)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(stateColor)
                }
            }
            Spacer()
            Button {
                state.isMinimalVoiceMode = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text("退出极简")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay { LingShuHUDCorners(accent: .white.opacity(0.4), cornerLength: 7) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func waveformBlock(label: String, color: Color, level: Float, active: Bool, caption: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(color.opacity(0.9))
                Spacer()
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            LingShuLiveWaveform(level: level, color: color, active: active)
                .frame(height: 96)
        }
    }

    private var micButton: some View {
        Button {
            LingShuPerceptionActions.toggleVoiceInput(
                state: state, voice: voice, perceptionGateway: perceptionGateway
            )
        } label: {
            Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(voice.isRecording ? .white : Color.lingVoid)
                .frame(width: 84, height: 84)
                .background(
                    voice.isRecording ? Color.red.opacity(0.9) : Color.lingHolo,
                    in: Circle()
                )
                .shadow(color: (voice.isRecording ? Color.red : Color.lingHolo).opacity(0.6), radius: 16)
        }
        .buttonStyle(.plain)
        .help(voice.isRecording ? "停止" : "开始说话")
    }

    private var captionForOutput: String {
        if voice.isSpeaking { return "正在回应" }
        if state.hasActiveModelCall { return "正在思考" }
        return "等待你的指令"
    }

    private var stateColor: Color {
        state.coreState.color
    }
}

/// 实时音频波形：维护一个滚动的电平历史，画成对称柱状波形。level 0...1 实时驱动。
struct LingShuLiveWaveform: View {
    var level: Float
    var color: Color
    var active: Bool

    @State private var history: [CGFloat] = Array(repeating: 0, count: 64)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { _ in
            Canvas { context, size in
                let count = history.count
                let gap: CGFloat = 3
                let barWidth = max(1.5, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                let midY = size.height / 2

                for (index, value) in history.enumerated() {
                    let x = CGFloat(index) * (barWidth + gap)
                    let h = max(2, value * size.height)
                    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                    // 越靠右（越新）越亮
                    let freshness = CGFloat(index) / CGFloat(count)
                    let opacity = 0.25 + 0.75 * freshness
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color.opacity(active ? opacity : opacity * 0.4))
                    )
                }
            }
            .onChange(of: tick) { _, _ in advance() }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
        )
        .overlay { LingShuHUDCorners(accent: color.opacity(0.4), cornerLength: 10) }
    }

    // 用一个随时间变化的离散值触发 history 推进（约 30fps）。
    private var tick: Int {
        Int(Date().timeIntervalSinceReferenceDate * 30)
    }

    private func advance() {
        var next = history
        next.removeFirst()
        // 加一点随机抖动，让等高电平也有自然起伏。
        let jitter = active ? CGFloat.random(in: 0.85...1.15) : 1
        next.append(min(1, CGFloat(level) * jitter))
        history = next
    }
}
