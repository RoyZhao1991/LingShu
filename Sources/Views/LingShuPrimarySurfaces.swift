import SwiftUI

struct LingShuRootView: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var lastVisionTraceAt = Date.distantPast
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
        .background(LingShuPreviewHost(controller: state.previewController))   // 大脑 open_preview → 弹出预览
        .sheet(item: $state.pendingShellApproval) { pending in
            LingShuPermissionApprovalView(pending: pending) { decision in
                state.resolveShellApproval(decision)
            }
        }
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
            // 新一轮开始时掐掉上一条朗读(防音频/文字 desync)。
            state.interruptSpeechOutput = { [weak voice] in voice?.stopSpeaking() }
            state.voiceManager = voice   // 供会议对话控制器经 MCP/UI 驱动

            perceptionGateway.registerCloudPerceptionRoute(client: state.cloudPerceptionClient)
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
        lingShuControlLog("speak: 朗读消息 id=\(message.id.uuidString.prefix(8)) 文本「\(String(message.text.prefix(40)))」")
        // 任务型交付只念简短摘要(避免整段念路径/英文/代码);对话/汇报型念全文。决策需模型,异步。
        Task { @MainActor in
            let toSpeak = await state.spokenReplyText(for: message)
            voice.speak(toSpeak)
        }
        perceptionGateway.ingestSpeechOutput(message.text)   // 感知/记忆仍用全文
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
                case .taskPool:
                    LingShuTaskPoolView(state: state)
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
    @State private var headerWidth: CGFloat = 1400

    var body: some View {
        // 顶栏随窗口宽度自适应：空间不足时先隐藏状态类文字，再紧到只剩导航图标——
        // 不再被压缩换行。
        let dense = headerWidth < 1300      // 隐藏感知值 / STATE·AUTO·TRUST / 副标题
        let compact = headerWidth < 1080    // 进一步：导航也只剩图标
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
                    if !dense {
                        Text("LINGSHU · GENERAL AGENT HUB")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(Color.lingHolo.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }

            LingShuTopPerceptionStrip(
                state: state,
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway,
                compact: dense
            )

            Spacer()

            HStack(spacing: 2) {
                ForEach(AppSurface.allCases) { surface in
                    let isSelected = state.selectedSurface == surface
                    Button {
                        state.selectedSurface = surface
                    } label: {
                        VStack(spacing: 5) {
                            Group {
                                if compact {
                                    Image(systemName: surface.icon)
                                } else {
                                    Label(surface.rawValue, systemImage: surface.icon)
                                }
                            }
                            .font(.system(size: compact ? 15 : 12.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)   // 标签(如"线程")不换行:按自然宽度排,别被宽图标挤成两行
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
                    .help(surface.rawValue)
                }
            }

            // STATE/AUTO/TRUST 是运行状态，始终显示（不随窗口变窄隐藏）。
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                LingShuHUDReadout(label: "STATE", value: state.coreStateDisplay, color: state.coreState.color)
            }
            LingShuHUDReadout(label: "AUTO", value: state.autonomousRunDisplayStatus, color: state.autonomousRun.isActive ? .orange : .lingFaint)
            LingShuHUDReadout(label: "TRUST", value: "\(state.trustScore)%", color: .lingHolo)

            Button {
                if !state.autonomousRun.isActive {
                    state.prepareAutonomousRun()
                }
                state.selectedSurface = .runtime
            } label: {
                Image(systemName: state.autonomousRun.isActive ? "bolt.circle.fill" : "bolt.circle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(state.autonomousRun.isActive ? Color.lingVoid : Color.lingHolo)
                    .frame(width: 34, height: 30)
                    .background(state.autonomousRun.isActive ? Color.orange : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { LingShuHUDCorners(accent: state.autonomousRun.isActive ? .orange : .lingHolo, cornerLength: 7) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("准备独立运行模式")

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
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.6))
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, newWidth in
                    headerWidth = newWidth
                }
            }
        }
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
