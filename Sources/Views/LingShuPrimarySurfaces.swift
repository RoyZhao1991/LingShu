import SwiftUI

struct LingShuRootView: View {
    @StateObject private var state = LingShuState()
    @StateObject private var voice = VoiceIOManager()
    @StateObject private var vision = VisionIOManager()
    @StateObject private var perceptionGateway = LingShuRealtimePerceptionGateway()
    @State private var lastVisionTraceAt = Date.distantPast
    @State private var didRunLaunchValidation = false
    private let coreTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
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
                case .operations:
                    LingShuOperationsSurface(state: state)
                case .settings:
                    LingShuModelGatewaySurface(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LingShuStableBackground())
        .preferredColorScheme(.dark)
        .onAppear {
            state.refreshCodexAuthStatusIfNeeded()
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
    var body: some View {
        ZStack {
            Color.lingVoid
            LinearGradient(
                colors: [
                    Color.lingHolo.opacity(0.14),
                    Color.clear,
                    Color.black.opacity(0.35)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }
        .ignoresSafeArea()
    }
}

struct LingShuStableTopBar: View {
    @ObservedObject var state: LingShuState
    @ObservedObject var voice: VoiceIOManager
    @ObservedObject var vision: VisionIOManager
    @ObservedObject var perceptionGateway: LingShuRealtimePerceptionGateway

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Color.lingVoid)
                    .frame(width: 36, height: 36)
                    .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("灵枢")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("对话式 AI 中枢，能力节点在后台协作。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
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

            HStack(spacing: 7) {
                ForEach(AppSurface.allCases) { surface in
                    Button {
                        state.selectedSurface = surface
                    } label: {
                        Label(surface.rawValue, systemImage: surface.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .foregroundStyle(state.selectedSurface == surface ? Color.lingVoid : .white.opacity(0.76))
                            .background(
                                state.selectedSurface == surface ? Color.lingHolo : Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(state.selectedSurface == surface ? 0 : 0.08))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            LingShuCompactStatus(title: "状态", value: state.coreStateDisplay, color: state.coreState.color)
            LingShuCompactStatus(title: "可信", value: "\(state.trustScore)%")

            Button {
                state.startDemoMissionIfConnected()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.lingVoid)
                    .frame(width: 36, height: 34)
                    .background(Color.lingHolo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("演示一次多 Agent 流转")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.lingHolo.opacity(0.18))
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
