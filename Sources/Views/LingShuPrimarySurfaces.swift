import SwiftUI

struct LingShuRootView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var lastVisionTraceAt = Date.distantPast
    @State private var didRunLaunchValidation = false
    private let coreTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if state.isMinimalVoiceMode {
                LingShuMinimalVoiceView(
                    state: state,
                    voice: voice,
                    vision: vision,
                    perceptionGateway: perceptionGateway
                )
                .frame(minWidth: 320, minHeight: 480)
            } else {
                standardLayout
                    .frame(minWidth: 1240, minHeight: 820)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: state.isMinimalVoiceMode) { _, minimal in
            LingShuWindowPlacement.applyMinimalVoiceWindow(minimal)
        }
        .onAppear {
            state.refreshCodexAuthStatusIfNeeded()
            state.livePerceptionContextProvider = { [weak perceptionGateway] in
                guard let perceptionGateway, perceptionGateway.hasLiveSignals else { return "" }
                return perceptionGateway.promptContext
            }
            // 对话发生时按需刷新云端场景理解（"台下有很多人"这类情境必须是当下的）。
            state.perceptionSceneRefreshTrigger = { [weak perceptionGateway] in
                perceptionGateway?.refreshSceneUnderstandingIfStale()
            }
            // 分句早读：语音输出开启时，流式回复每攒满一句立即排队播报，
            // 不必等整段回复生成完才开口。
            state.streamingSentenceSpeaker = { [weak state, weak voice, weak perceptionGateway] sentence in
                guard let state, let voice,
                      state.voiceOutputEnabled || state.isMinimalVoiceMode else { return }
                voice.speakQueued(sentence)
                perceptionGateway?.ingestSpeechOutput(sentence)
            }
            perceptionGateway.registerCloudPerceptionRoute(client: state.cloudPerceptionClient)
            if !didRunLaunchValidation,
               ProcessInfo.processInfo.arguments.contains("--lingshu-engineering-validation") {
                didRunLaunchValidation = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    state.runEngineeringValidationSuite()
                }
            }
            [0.1, 0.8, 1.6].forEach { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    LingShuWindowPlacement.bringWindowsToMainScreen()
                }
            }
        }
        .onChange(of: state.apiKey) { _, _ in
            perceptionGateway.registerCloudPerceptionRoute(client: state.cloudPerceptionClient)
        }
        .onChange(of: state.modelProvider) { _, _ in
            perceptionGateway.registerCloudPerceptionRoute(client: state.cloudPerceptionClient)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.flushChatHistory()
            state.taskExecutionJournal.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startDemoMission)) { _ in
            state.startDemoMissionIfConnected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .runEngineeringValidation)) { _ in
            state.runEngineeringValidationSuite()
        }
        .onReceive(coreTimer) { _ in
            state.tickCoreTimers()
        }
        .onReceive(vision.$latestObservation) { observation in
            if let observation {
                perceptionGateway.ingestVisionObservation(observation)
            }
            traceVisionObservationIfNeeded(observation)
        }
        .onReceive(vision.$latestFramePacket) { packet in
            if let packet {
                perceptionGateway.ingestVideoFrame(packet)
            }
        }
        .onReceive(state.$chatMessages) { messages in
            speakLatestReplyIfNeeded(messages)
        }
    }

    /// 灵枢新回复就播报。集中在根视图，确保普通界面和极简语音模式都会发声。
    private func speakLatestReplyIfNeeded(_ messages: [ChatMessage]) {
        let shouldSpeak = state.voiceOutputEnabled || state.isMinimalVoiceMode
        guard shouldSpeak,
              let message = messages.last(where: { !$0.isUser && !$0.isLoading }),
              message.id != state.lastSpokenMessageID else {
            return
        }

        state.lastSpokenMessageID = message.id
        voice.speak(message.text)
        perceptionGateway.ingestSpeechOutput(message.text)
    }

    private var standardLayout: some View {
        VStack(spacing: 0) {
            LingShuStableTopBar(
                state: state,
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway
            )

            Group {
                switch state.selectedSurface {
                case .chat:
                    LingShuDialogueSurface(
                        state: state,
                        voice: voice,
                        vision: vision,
                        perceptionGateway: perceptionGateway
                    )
                case .runtime:
                    LingShuRuntimeSurface(state: state, voice: voice)
                case .operations:
                    LingShuOperationsSurface(state: state)
                case .settings:
                    LingShuSettingsHub(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LingShuStableBackground(accent: state.coreState.color))
    }

    private func traceVisionObservationIfNeeded(_ observation: LingShuVisionObservation?) {
        guard let observation, vision.isCameraRunning else { return }
        guard Date().timeIntervalSince(lastVisionTraceAt) >= 6 else { return }

        lastVisionTraceAt = Date()
        state.appendTrace(
            kind: .system,
            actor: "视觉",
            title: "实时观测",
            detail: observation.summary
        )
    }
}

struct LingShuStableBackground: View {
    var accent: Color = .lingHolo

    var body: some View {
        LingShuHUDBackground(accent: accent)
    }
}

struct LingShuStableTopBar: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 11) {
                ZStack {
                    LingShuHoloCoreView(
                        color: state.coreState.color,
                        intensity: state.coreState == .standby ? 0.12 : 0.8,
                        isAbnormal: state.coreState == .abnormal
                    )
                    .frame(width: 34, height: 34)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("灵枢")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("LINGSHU · GENERAL AGENT HUB")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Color.lingHolo.opacity(0.6))
                        .lineLimit(1)
                }
            }

            LingShuTopPerceptionStrip(
                state: state,
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway
            )

            Spacer()

            HStack(spacing: 2) {
                ForEach(AppSurface.allCases) { surface in
                    let isSelected = state.selectedSurface == surface
                    Button {
                        state.selectedSurface = surface
                    } label: {
                        VStack(spacing: 5) {
                            Label(surface.rawValue, systemImage: surface.icon)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.lingHolo : .white.opacity(0.6))
                            Rectangle()
                                .fill(isSelected ? Color.lingHolo : .clear)
                                .frame(height: 2)
                                .shadow(color: isSelected ? Color.lingHolo.opacity(0.8) : .clear, radius: 4)
                        }
                        .padding(.horizontal, 13)
                        .padding(.top, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                LingShuHUDReadout(label: "STATE", value: state.coreStateDisplay, color: state.coreState.color)
            }
            LingShuHUDReadout(label: "TRUST", value: "\(state.trustScore)%", color: .lingHolo)

            Button {
                state.isMinimalVoiceMode = true
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.lingVoid)
                    .frame(width: 34, height: 30)
                    .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("进入极简语音模式（双波形纯语音对话）")

            Button {
                state.startDemoMissionIfConnected()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                    .frame(width: 34, height: 30)
                    .overlay { LingShuHUDCorners(accent: .lingHolo, cornerLength: 7) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("演示一次多 Agent 流转")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.6))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, Color.lingHolo.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }
}

struct LingShuCompactStatus: View {
    let title: String
    let value: String
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
