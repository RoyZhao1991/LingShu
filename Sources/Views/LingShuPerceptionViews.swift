import SwiftUI

struct LingShuTopPerceptionStrip: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var isDetailPresented = false

    var body: some View {
        Button {
            isDetailPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                PerceptionDotStatus(title: "耳", value: earStatusText, isActive: state.voiceWakeListeningEnabled)
                PerceptionDotStatus(title: "嘴", value: mouthStatusText, isActive: mouthIsActive)
                PerceptionDotStatus(title: "眼", value: vision.isCameraRunning ? "看" : "待机", isActive: vision.isCameraRunning)
                PerceptionDotStatus(title: "主", value: perceptionGateway.ownerIdentitySnapshot.shortStatus, isActive: perceptionGateway.isOwnerIdentityLocked)
                PerceptionDotStatus(
                    title: "析",
                    value: perceptionGateway.isRemoteRouteActive ? "模型" : "本地",
                    isActive: !perceptionGateway.statusText.contains("中断")
                )
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
        .help("查看实时感知状态")
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
            return "对话"
        }

        return state.voiceWakeListeningEnabled ? "待唤醒" : "待机"
    }

    private var mouthStatusText: String {
        if voice.isSpeaking {
            return "说"
        }
        if !state.voiceOutputEnabled {
            return "静音"
        }
        return isSpeechOutputConfigured ? "待命" : "待配置"
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

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.62))
                .frame(width: 7, height: 7)
                .shadow(color: isActive ? Color.green.opacity(0.55) : .clear, radius: 4)

            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))

            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
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
                Text("实时感知")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text(perceptionGateway.activeRoute.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.lingHolo)
            }

            VStack(alignment: .leading, spacing: 8) {
                PerceptionDetailRow(label: "耳朵", value: voice.inputStatusMessage, isActive: voice.isRecording)
                PerceptionDetailRow(label: "嘴巴", value: state.voiceOutputEnabled ? voice.outputStatusMessage : "静音", isActive: state.voiceOutputEnabled)
                PerceptionDetailRow(label: "眼睛", value: vision.statusMessage, isActive: vision.isCameraRunning)
                PerceptionDetailRow(label: "认主", value: perceptionGateway.ownerIdentitySnapshot.statusText, isActive: perceptionGateway.isOwnerIdentityLocked)
                PerceptionDetailRow(label: "解析", value: perceptionGateway.statusText, isActive: !perceptionGateway.statusText.contains("中断"))
            }

            LingShuOwnerIdentityPanel(perceptionGateway: perceptionGateway, voice: voice, vision: vision)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("语音理解")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 56, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { voice.transcriptionProvider.id },
                        set: { providerID in
                            guard let provider = voice.availableTranscriptionProviders.first(where: { $0.id == providerID }) else { return }
                            voice.transcriptionProvider = provider
                        }
                    )) {
                        ForEach(voice.availableTranscriptionProviders) { provider in
                            Text(provider.displayName).tag(provider.id)
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
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("重新检测本地语音模型")
                }

                Text(voice.transcriptionProvider.note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    Circle()
                        .fill(voice.embeddedASRStatus.isAvailable ? Color.green : Color.gray.opacity(0.62))
                        .frame(width: 7, height: 7)

                    Text("SenseVoice")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))

                    Text(voice.embeddedASRStatus.compactDiagnostic)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(voice.embeddedASRStatus.isAvailable ? Color.green.opacity(0.85) : .white.opacity(0.46))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.1))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("语音输出")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 56, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { voice.speechOutputProvider.id },
                        set: { providerID in
                            voice.applySpeechOutputProvider(providerID)
                        }
                    )) {
                        ForEach(voice.availableSpeechOutputProviders) { provider in
                            Text(provider.displayName).tag(provider.id)
                                .disabled(!provider.isRuntimeAvailable)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Text("音色")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 56, alignment: .leading)

                    Picker("", selection: Binding<String>(
                        get: { voice.speechPersona.id },
                        set: { personaID in
                            voice.applySpeechPersona(personaID)
                        }
                    )) {
                        ForEach(voice.availableSpeechPersonas) { persona in
                            Text(persona.displayName).tag(persona.id)
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.lingHolo.opacity(0.14))
                        }
                }

                Text(voice.speechOutputProvider.note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    let isConfigured = LingShuTopPerceptionStrip.isConfiguredSpeechEndpoint(voice.speechOutputEndpoint)
                    Circle()
                        .fill(isConfigured ? Color.green : Color.gray.opacity(0.62))
                        .frame(width: 7, height: 7)

                    Text("云端 TTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))

                    Text(isConfigured ? "已配置" : "待配置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isConfigured ? Color.green.opacity(0.85) : .white.opacity(0.46))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.1))
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("使用触发词", isOn: $state.requiresVoiceWakeWord)
                    .toggleStyle(.switch)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))

                HStack(spacing: 8) {
                    Text("触发词")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 42, alignment: .leading)

                    TextField("灵枢", text: $state.voiceWakeWord)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.lingHolo.opacity(0.14))
                        }
                }

                Text(voiceModeHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.lingHolo.opacity(0.1))
            }

            HStack(spacing: 8) {
                PerceptionActionButton(
                    title: state.voiceWakeListeningEnabled ? "停止收音" : "启用收音",
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
                    title: state.voiceOutputEnabled ? "关闭发声" : "启用发声",
                    icon: state.voiceOutputEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    isActive: state.voiceOutputEnabled
                ) {
                    state.voiceOutputEnabled.toggle()
                }

                PerceptionActionButton(
                    title: vision.isCameraRunning ? "关闭视觉" : "启用视觉",
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
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("\(perceptionGateway.eventCount)", systemImage: "dot.radiowaves.left.and.right")
                Label("\(perceptionGateway.rawForwardedCount)", systemImage: "arrow.up.right")
                Spacer()

                if let observation = vision.latestObservation {
                    Button {
                        appendVisionContext(observation)
                    } label: {
                        Text("交给灵枢")
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
            .foregroundStyle(.white.opacity(0.46))
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
            return "收音开启后会直接进入实时对话。"
        }

        let wakeWord = state.voiceWakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        return "先说“\(wakeWord.isEmpty ? "灵枢" : wakeWord)”唤醒，再说具体指令。"
    }

    private func appendVisionContext(_ observation: LingShuVisionObservation) {
        if !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.prompt += "\n"
        }

        state.prompt += observation.promptContext
    }
}

struct PerceptionActionButton: View {
    let title: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.lingVoid : .white.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    isActive ? Color.lingHolo : Color.white.opacity(0.075),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.lingHolo.opacity(isActive ? 0 : 0.16))
                }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct PerceptionDetailRow: View {
    let label: String
    let value: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.gray.opacity(0.62))
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 36, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}
