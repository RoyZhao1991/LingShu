import Foundation

/// 连续语音对话控制器（豆包视频通话式）：进入即自动监听，靠 VAD 静音断句自动收口、
/// 自动应答、应答完自动接着听，全程免手。灵枢说话/思考时暂停麦克风避免回声，并支持打断。
@MainActor
final class LingShuVoiceCallController: ObservableObject {
    enum Phase: Equatable {
        case idle          // 待机/未开始
        case listening     // 正在听你说
        case capturing     // 已检测到说话，等你说完
        case thinking      // 灵枢正在判断
        case responding    // 灵枢正在回应（TTS）

        var caption: String {
            switch self {
            case .idle: "未开始"
            case .listening: "在听你说…"
            case .capturing: "在听你说…"
            case .thinking: "灵枢在思考…"
            case .responding: "灵枢正在回应…"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    private weak var state: LingShuState?
    private weak var voice: VoiceIOManager?
    private weak var perceptionGateway: LingShuRealtimePerceptionGateway?
    private var loopTask: Task<Void, Never>?

    // VAD 阈值：电平高于 speakThreshold 视为说话；说话后低于 silenceThreshold 持续
    // silenceHold 秒视为一句结束。bargeInThreshold 用于灵枢说话时的打断。
    private let speakThreshold: Float = 0.12
    private let silenceThreshold: Float = 0.06
    private let silenceHold: TimeInterval = 1.0
    private let bargeInThreshold: Float = 0.2
    private let tickInterval: UInt64 = 80_000_000 // 80ms ≈ 12.5Hz

    private var hasCapturedSpeech = false
    private var silenceStartedAt: Date?
    private var bargeInStartedAt: Date?

    var isActive: Bool { loopTask != nil }

    func start(
        state: LingShuState,
        voice: VoiceIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway
    ) {
        guard loopTask == nil else { return }
        self.state = state
        self.voice = voice
        self.perceptionGateway = perceptionGateway

        LingShuPerceptionActions.startContinuousConversation(
            state: state, voice: voice, perceptionGateway: perceptionGateway
        )
        phase = .listening
        resetUtterance()
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        if let state, let voice {
            LingShuPerceptionActions.stopConversation(state: state, voice: voice)
        }
        phase = .idle
        resetUtterance()
    }

    private func resetUtterance() {
        hasCapturedSpeech = false
        silenceStartedAt = nil
        bargeInStartedAt = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            tick()
            try? await Task.sleep(nanoseconds: tickInterval)
        }
    }

    private func tick() {
        guard let state, let voice, let perceptionGateway else { return }
        let level = voice.inputLevel
        let now = Date()

        // 灵枢正在回应（含分句早读的排队间隙）：暂停麦克风避免回声；监听用户是否要打断。
        if voice.isSpeakingOrQueued {
            phase = .responding
            if voice.isRecording { voice.stopRecognition() }
            if level > bargeInThreshold {
                if let started = bargeInStartedAt {
                    if now.timeIntervalSince(started) > 0.25 {
                        // 用户开口打断：停掉 TTS，立即重新听。
                        voice.stopSpeaking()
                        bargeInStartedAt = nil
                        resetUtterance()
                        LingShuPerceptionActions.resumeListening(state: state, voice: voice, perceptionGateway: perceptionGateway)
                        phase = .listening
                    }
                } else {
                    bargeInStartedAt = now
                }
            } else {
                bargeInStartedAt = nil
            }
            return
        }

        // 灵枢正在思考：等结果，不收音。
        if state.hasActiveModelCall {
            phase = .thinking
            if voice.isRecording { voice.stopRecognition() }
            resetUtterance()
            return
        }

        // 空闲：确保在监听，并跑 VAD 断句。
        if !voice.isRecording {
            LingShuPerceptionActions.resumeListening(state: state, voice: voice, perceptionGateway: perceptionGateway)
        }

        if level >= speakThreshold {
            hasCapturedSpeech = true
            silenceStartedAt = nil
            phase = .capturing
        } else if hasCapturedSpeech, level < silenceThreshold {
            if let started = silenceStartedAt {
                if now.timeIntervalSince(started) >= silenceHold {
                    // 一句话说完：收口，触发最终识别并自动提交。
                    voice.finishCurrentUtterance()
                    resetUtterance()
                    phase = .thinking
                }
            } else {
                silenceStartedAt = now
            }
        } else if phase != .capturing {
            phase = .listening
        }
    }
}
