import SwiftUI

struct LingShuPerceptionPanel: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PerceptionStatusPill(
                    title: "耳朵",
                    value: voice.isRecording ? "正在听" : "待机",
                    icon: voice.isRecording ? "waveform" : "ear",
                    color: voice.isRecording ? .red : .lingHolo
                )

                PerceptionStatusPill(
                    title: "嘴巴",
                    value: state.voiceOutputEnabled ? (voice.isSpeaking ? "发声中" : "可发声") : "静音",
                    icon: state.voiceOutputEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    color: state.voiceOutputEnabled ? .lingHolo : .white.opacity(0.46)
                )

                PerceptionStatusPill(
                    title: "眼睛",
                    value: vision.isCameraRunning ? "视觉在线" : "待机",
                    icon: vision.isCameraRunning ? "eye.fill" : "eye",
                    color: vision.isCameraRunning ? .cyan : .lingHolo
                )

                PerceptionStatusPill(
                    title: "解析",
                    value: perceptionGateway.activeRoute.displayName,
                    icon: perceptionGateway.isRemoteRouteActive ? "network" : "cpu",
                    color: perceptionGateway.isRemoteRouteActive ? .cyan : .lingHolo
                )

                Spacer(minLength: 8)

                if let observation = vision.latestObservation {
                    Button {
                        appendVisionContext(observation)
                    } label: {
                        Label("交给灵枢", systemImage: "arrow.turn.down.left")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.lingVoid)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("把当前视觉观测写入输入框")
                }
            }

            if vision.isCameraRunning || perceptionGateway.eventCount > 0 {
                HStack(alignment: .top, spacing: 10) {
                    if vision.isCameraRunning {
                        CameraPreviewView(session: vision.captureSession)
                            .frame(width: 148, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.lingHolo.opacity(0.24))
                            }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(primaryPerceptionSummary)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(2)

                        if let observation = vision.latestObservation {
                            HStack(spacing: 10) {
                                Label("\(observation.faceCount)", systemImage: "person.crop.circle")
                                Label("\(observation.frameWidth)x\(observation.frameHeight)", systemImage: "rectangle.dashed")
                                Label(observation.recognizedText.isEmpty ? "无文字" : "有文字", systemImage: "text.viewfinder")
                            }
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.46))

                            if !observation.recognizedText.isEmpty {
                                Text(observation.recognizedText)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.lingHolo.opacity(0.82))
                                    .lineLimit(1)
                            }
                        }

                        HStack(spacing: 10) {
                            Label("\(perceptionGateway.eventCount)", systemImage: "dot.radiowaves.left.and.right")
                            Label(perceptionGateway.statusText, systemImage: perceptionGateway.isRemoteRouteActive ? "network" : "cpu")
                            if perceptionGateway.rawForwardedCount > 0 {
                                Label("\(perceptionGateway.rawForwardedCount)", systemImage: "arrow.up.right")
                            }
                        }
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.052), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.lingHolo.opacity(vision.isCameraRunning || voice.isRecording ? 0.26 : 0.12))
        }
    }

    private func appendVisionContext(_ observation: LingShuVisionObservation) {
        if !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.prompt += "\n"
        }

        state.prompt += observation.promptContext
    }

    private var primaryPerceptionSummary: String {
        let modelFeedback = perceptionGateway.lastModelFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelFeedback.isEmpty {
            return modelFeedback
        }

        return vision.latestObservation?.summary ?? perceptionGateway.lastEventSummary
    }
}

struct PerceptionStatusPill: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.46))
                Text(value)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(0.16))
        }
    }
}
