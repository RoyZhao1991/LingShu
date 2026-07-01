import SwiftUI

struct LingShuPerceptionPanel: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway
    @State private var isRunningSelfTest = false
    @State private var selfTestReport: LingShuPerceptionSelfTestReport?

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
                    color: state.voiceOutputEnabled ? .lingHolo : Color.lingFg.opacity(0.46)
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

                Button {
                    runSelfTest()
                } label: {
                    Label(isRunningSelfTest ? "自检中…" : "感知自检", systemImage: "stethoscope")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.lingHolo)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .overlay { LingShuHUDCorners(accent: .lingHolo, cornerLength: 7) }
                }
                .buttonStyle(.plain)
                .disabled(isRunningSelfTest)
                .help("逐项实测麦克风、识别、合成、摄像头、视觉解析、云感知与身份锁")

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
                            .foregroundStyle(Color.lingFg.opacity(0.84))
                            .lineLimit(2)

                        if let observation = vision.latestObservation {
                            HStack(spacing: 10) {
                                Label("\(observation.faceCount)", systemImage: "person.crop.circle")
                                Label("\(observation.frameWidth)x\(observation.frameHeight)", systemImage: "rectangle.dashed")
                                Label(observation.recognizedText.isEmpty ? "无文字" : "有文字", systemImage: "text.viewfinder")
                            }
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.lingFg.opacity(0.46))

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
                        .foregroundStyle(Color.lingFg.opacity(0.46))
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(Color.lingFg.opacity(0.052), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.lingHolo.opacity(vision.isCameraRunning || voice.isRecording ? 0.26 : 0.12))
        }
        .sheet(item: Binding(
            get: { selfTestReport.map { SelfTestReportBox(report: $0) } },
            set: { _ in selfTestReport = nil }
        )) { box in
            PerceptionSelfTestReportSheet(report: box.report)
        }
    }

    private struct SelfTestReportBox: Identifiable {
        let id = UUID()
        let report: LingShuPerceptionSelfTestReport
    }

    private func runSelfTest() {
        isRunningSelfTest = true
        Task {
            let report = await LingShuPerceptionSelfTest.run(
                voice: voice,
                vision: vision,
                perceptionGateway: perceptionGateway,
                cloudClient: state.cloudPerceptionClient
            )
            selfTestReport = report
            isRunningSelfTest = false
            state.appendTrace(kind: .system, actor: "感知自检", title: "自检完成", detail: report.summaryLine)
            for item in report.items {
                state.appendTrace(
                    kind: item.verdict == .fail ? .warning : .system,
                    actor: "感知自检",
                    title: "\(item.name)：\(item.verdict.label)",
                    detail: item.latencyMillis.map { "\(item.detail)（\($0)ms）" } ?? item.detail
                )
            }
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

/// 感知自检结果面板：逐项展示真实测得的结论与延迟。
struct PerceptionSelfTestReportSheet: View {
    let report: LingShuPerceptionSelfTestReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("感知自检报告", systemImage: "stethoscope")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.lingFg)
                Spacer()
                Text(report.summaryLine)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(report.failCount > 0 ? .orange : Color.lingHolo)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Color.lingFg.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.black.opacity(0.6))

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(report.items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: item.verdict))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(color(for: item.verdict))
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(item.name)
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(Color.lingFg.opacity(0.92))
                                    Text(item.verdict.label)
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundStyle(color(for: item.verdict))
                                    if let latency = item.latencyMillis {
                                        Text("\(latency)ms")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.lingFg.opacity(0.4))
                                    }
                                }
                                Text(item.detail)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.lingFg.opacity(0.6))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color.lingVoid)
    }

    private func icon(for verdict: LingShuPerceptionSelfTestItem.Verdict) -> String {
        switch verdict {
        case .pass: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(for verdict: LingShuPerceptionSelfTestItem.Verdict) -> Color {
        switch verdict {
        case .pass: Color.lingHolo
        case .degraded: .orange
        case .fail: .red
        case .skipped: Color.lingFg.opacity(0.4)
        }
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
                    .foregroundStyle(Color.lingFg.opacity(0.46))
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
