import SwiftUI

struct LingShuTopPerceptionStrip: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    /// 顶栏空间不足时只显示圆点+单字（隐藏状态值文字）。
    var compact: Bool = false
    @State private var isDetailPresented = false

    var body: some View {
        Button {
            isDetailPresented.toggle()
        } label: {
            HStack(spacing: compact ? 8 : 10) {
                PerceptionDotStatus(title: state.loc("耳", "Ear"), value: earStatusText, isActive: state.voiceWakeListeningEnabled, compact: compact)
                PerceptionDotStatus(title: state.loc("嘴", "Voice"), value: mouthStatusText, isActive: mouthIsActive, compact: compact)
                PerceptionDotStatus(title: state.loc("眼", "Eye"), value: vision.isCameraRunning ? state.loc("看", "On") : state.loc("待机", "Idle"), isActive: vision.isCameraRunning, compact: compact)
                PerceptionDotStatus(
                    title: state.loc("主", "Owner"),
                    value: perceptionGateway.ownerIdentitySnapshot.shortStatus(language: state.language),
                    isActive: perceptionGateway.isOwnerIdentityLocked,
                    compact: compact
                )
                PerceptionDotStatus(
                    title: state.loc("析", "Sense"),
                    value: perceptionGateway.isRemoteRouteActive ? state.loc("模型", "Cloud") : state.loc("本地", "Local"),
                    isActive: !perceptionGateway.statusText.contains("中断"),
                    compact: compact
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.lingFg.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .help(state.loc("查看实时感知状态", "View real-time perception status"))
        .popover(isPresented: $isDetailPresented, arrowEdge: .bottom) {
            LingShuPerceptionPopoverContent(
                state: state,
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway
            )
            .frame(width: 360)
            .padding(14)
            .background(Color.lingVoid)
        }
    }

    private var earStatusText: String {
        if state.isVoiceConversationActive {
            return state.loc("对话", "Live")
        }

        return state.voiceWakeListeningEnabled ? state.loc("待唤醒", "Awaiting wake word") : state.loc("待机", "Idle")
    }

    private var mouthStatusText: String {
        if voice.isSpeaking {
            return state.loc("说", "Speaking")
        }
        if !state.voiceOutputEnabled {
            return state.loc("静音", "Muted")
        }
        return isSpeechOutputConfigured ? state.loc("待命", "Ready") : state.loc("待配置", "Setup")
    }

    private var mouthIsActive: Bool {
        state.voiceOutputEnabled && isSpeechOutputConfigured
    }

    private var isSpeechOutputConfigured: Bool {
        Self.isConfiguredSpeechEndpoint(voice.speechOutputEndpoint)
    }

    fileprivate static func isConfiguredSpeechEndpoint(_ endpoint: String) -> Bool {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !trimmed.isEmpty
            && !trimmed.contains("example.com")
            && !trimmed.contains("your-")
    }
}

struct PerceptionDotStatus: View {
    let title: String
    let value: String
    let isActive: Bool
    /// 空间不足时只保留圆点+单字标题，隐藏状态值文字（避免被压缩/换行）。
    var compact: Bool = false

    static func displayTitle(_ title: String, compact: Bool) -> String {
        compact ? String(title.prefix(1)) : title
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.62))
                .frame(width: 7, height: 7)
                .shadow(color: isActive ? Color.green.opacity(0.55) : .clear, radius: 4)

            Text(Self.displayTitle(title, compact: compact))
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Color.lingFg.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .fixedSize(horizontal: true, vertical: false)

            if !compact {
                Text(value)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.lingFg.opacity(0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }
}

struct LingShuPerceptionPopoverContent: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.loc("实时感知", "Real-time Perception"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.lingFg)

                Spacer()

                Text(perceptionGateway.activeRoute.localizedDisplayName(language: state.language))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.lingHolo)
            }

            VStack(alignment: .leading, spacing: 8) {
                PerceptionDetailRow(
                    label: state.loc("耳朵", "Audio In"),
                    value: state.localizedRuntimeText(voice.inputStatusMessage, fallback: voice.isRecording ? "Listening" : "Audio input idle"),
                    isActive: voice.isRecording
                )
                PerceptionDetailRow(
                    label: state.loc("嘴巴", "Audio Out"),
                    value: state.voiceOutputEnabled
                        ? state.localizedRuntimeText(voice.outputStatusMessage, fallback: voice.isSpeaking ? "Speaking" : "Audio output ready")
                        : state.loc("静音", "Muted"),
                    isActive: state.voiceOutputEnabled
                )
                PerceptionDetailRow(
                    label: state.loc("眼睛", "Vision"),
                    value: state.localizedRuntimeText(vision.statusMessage, fallback: vision.isCameraRunning ? "Vision online" : "Vision idle"),
                    isActive: vision.isCameraRunning
                )
                PerceptionDetailRow(
                    label: state.loc("认主", "Owner"),
                    value: perceptionGateway.ownerIdentitySnapshot.localizedStatusText(language: state.language),
                    isActive: perceptionGateway.isOwnerIdentityLocked
                )
                PerceptionDetailRow(
                    label: state.loc("解析", "Analysis"),
                    value: state.localizedRuntimeText(perceptionGateway.statusText, fallback: "Perception ready"),
                    isActive: !perceptionGateway.statusText.contains("中断")
                )
            }

            LingShuOwnerIdentityPanel(perceptionGateway: perceptionGateway, voice: voice, vision: vision)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(state.loc("语音理解", "Speech Input"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.48))
                        .frame(width: 56, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { voice.transcriptionProvider.id },
                        set: { providerID in
                            guard let provider = voice.availableTranscriptionProviders.first(where: { $0.id == providerID }) else { return }
                            voice.transcriptionProvider = provider
                        }
                    )) {
                        ForEach(voice.availableTranscriptionProviders) { provider in
                            Text(provider.localizedDisplayName(language: state.language)).tag(provider.id)
                                .disabled(!provider.isRuntimeAvailable)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Button {
                        voice.refreshEmbeddedASRRuntimeStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Color.lingHolo)
                            .frame(width: 24, height: 24)
                            .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(state.loc("重新检测本地语音模型", "Check local speech model again"))
                }

                Text(voice.transcriptionProvider.localizedNote(language: state.language))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    Circle()
                        .fill(voice.embeddedASRStatus.isAvailable ? Color.green : Color.gray.opacity(0.62))
                        .frame(width: 7, height: 7)

                    Text("SenseVoice")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.56))

                    Text(voice.embeddedASRStatus.localizedCompactDiagnostic(language: state.language))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(voice.embeddedASRStatus.isAvailable ? Color.green.opacity(0.85) : Color.lingFg.opacity(0.46))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.1))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(state.loc("语音输出", "Speech Output"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.48))
                        .frame(width: 56, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { voice.speechOutputProvider.id },
                        set: { providerID in
                            voice.applySpeechOutputProvider(providerID)
                        }
                    )) {
                        ForEach(voice.availableSpeechOutputProviders) { provider in
                            Text(provider.localizedDisplayName(language: state.language)).tag(provider.id)
                                .disabled(!provider.isRuntimeAvailable)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Text(state.loc("音色", "Voice"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.48))
                        .frame(width: 56, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { voice.speechPersona.id },
                        set: { personaID in
                            voice.applySpeechPersona(personaID)
                        }
                    )) {
                        ForEach(voice.availableSpeechPersonas) { persona in
                            Text(persona.localizedDisplayName(language: state.language)).tag(persona.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Spacer(minLength: 0)
                }

                if voice.speechOutputProvider.kind != .appleSpeech,
                   voice.speechOutputProvider.kind != .embeddedSherpaONNXTTS {
                    TextField("TTS endpoint", text: $voice.speechOutputEndpoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.lingFg)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Color.lingFg.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.lingHolo.opacity(0.14))
                        }
                }

                Text(voice.speechOutputProvider.localizedNote(language: state.language))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    let isConfigured = LingShuTopPerceptionStrip.isConfiguredSpeechEndpoint(voice.speechOutputEndpoint)
                    Circle()
                        .fill(isConfigured ? Color.green : Color.gray.opacity(0.62))
                        .frame(width: 7, height: 7)

                    Text(state.loc("云端 TTS", "Cloud TTS"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.56))

                    Text(isConfigured ? state.loc("已配置", "Configured") : state.loc("待配置", "Setup Needed"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isConfigured ? Color.green.opacity(0.85) : Color.lingFg.opacity(0.46))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.1))
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(state.loc("使用触发词", "Require Wake Word"), isOn: $state.requiresVoiceWakeWord)
                    .toggleStyle(.switch)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.lingFg.opacity(0.72))

                HStack(spacing: 8) {
                    Text(state.loc("触发词", "Wake Word"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.48))
                        .frame(width: 42, alignment: .leading)

                    TextField(state.loc("灵枢", "Nous"), text: $state.voiceWakeWord)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Color.lingFg.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.lingHolo.opacity(0.14))
                        }
                }

                Text(voiceModeHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.1))
            }

            HStack(spacing: 8) {
                PerceptionActionButton(
                    title: state.voiceWakeListeningEnabled ? state.loc("停止收音", "Stop Listening") : state.loc("启用收音", "Start Listening"),
                    icon: voice.isRecording ? "mic.slash.fill" : "mic.fill",
                    isActive: state.voiceWakeListeningEnabled
                ) {
                    LingShuPerceptionActions.toggleVoiceInput(
                        state: state,
                        voice: voice,
                        perceptionGateway: perceptionGateway
                    )
                }

                PerceptionActionButton(
                    title: state.voiceOutputEnabled ? state.loc("关闭发声", "Mute Voice") : state.loc("启用发声", "Enable Voice"),
                    icon: state.voiceOutputEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    isActive: state.voiceOutputEnabled
                ) {
                    state.voiceOutputEnabled.toggle()
                }

                PerceptionActionButton(
                    title: vision.isCameraRunning ? state.loc("关闭视觉", "Stop Vision") : state.loc("启用视觉", "Start Vision"),
                    icon: vision.isCameraRunning ? "eye.slash.fill" : "eye.fill",
                    isActive: vision.isCameraRunning
                ) {
                    LingShuPerceptionActions.toggleVision(state: state, vision: vision)
                }
            }

            if vision.isCameraRunning {
                CameraPreviewView(session: vision.captureSession)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.lingHolo.opacity(0.18))
                    }
            }

            Text(primaryPerceptionSummary)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("\(perceptionGateway.eventCount)", systemImage: "dot.radiowaves.left.and.right")
                Label("\(perceptionGateway.rawForwardedCount)", systemImage: "arrow.up.right")
                Spacer()

                if let observation = vision.latestObservation {
                    Button {
                        appendVisionContext(observation)
                    } label: {
                        Text(state.loc("交给灵枢", "Send to Nous"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.lingVoid)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.lingFg.opacity(0.46))
        }
    }

    private var primaryPerceptionSummary: String {
        let modelFeedback = perceptionGateway.lastModelFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelFeedback.isEmpty {
            return modelFeedback
        }

        return vision.latestObservation?.summary ?? perceptionGateway.lastEventSummary
    }

    private var voiceModeHint: String {
        if !state.requiresVoiceWakeWord {
            return state.loc("收音开启后会直接进入实时对话。", "Listening starts a real-time conversation immediately.")
        }

        let wakeWord = state.voiceWakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackWakeWord = state.loc("灵枢", "Nous")
        return state.loc(
            "先说“\(wakeWord.isEmpty ? fallbackWakeWord : wakeWord)”唤醒，再说具体指令。",
            "Say “\(wakeWord.isEmpty ? fallbackWakeWord : wakeWord)” first, then give your instruction."
        )
    }

    private func appendVisionContext(_ observation: LingShuVisionObservation) {
        if !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.prompt += "\n"
        }

        state.prompt += observation.promptContext
    }
}
