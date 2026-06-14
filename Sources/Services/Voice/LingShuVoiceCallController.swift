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

    // VAD 阈值自适应：跟踪环境噪声底，嘈杂环境自动抬高说话/收口/打断门槛，
    // 屏蔽底噪对主人指令断句的干扰。
    private var adaptiveVAD = LingShuAdaptiveVAD()
    private let silenceHold: TimeInterval = 1.0
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

        adaptiveVAD.observe(level: level, isCapturingSpeech: hasCapturedSpeech || voice.isSpeakingOrQueued)

        // 灵枢正在回应（TTS）：暂停麦克风避免自听；只在【确认是真指令】(持续真实说话 ≥0.7s)才打断，
        // 短促噪音/回声忽略。
        if voice.isSpeakingOrQueued {
            phase = .responding
            if voice.isRecording { voice.stopRecognition() }
            if level > adaptiveVAD.bargeInThreshold {
                if let started = bargeInStartedAt {
                    if now.timeIntervalSince(started) > 0.7 {
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

        // 灵枢正在思考：**不停麦**,继续听。噪音(达不到 VAD 说话门槛)直接忽略;
        // 确认是真指令(持续说话 → 收口)才打断在飞调用并接管。
        let thinking = state.hasActiveModelCall

        if !voice.isRecording {
            LingShuPerceptionActions.resumeListening(state: state, voice: voice, perceptionGateway: perceptionGateway)
        }

        if level >= adaptiveVAD.speakThreshold {
            hasCapturedSpeech = true
            silenceStartedAt = nil
            phase = .capturing
        } else if hasCapturedSpeech, level < adaptiveVAD.silenceThreshold {
            if let started = silenceStartedAt {
                if now.timeIntervalSince(started) >= silenceHold {
                    // 一句真话说完(已过 VAD 噪音门槛):若正在思考,先打断在飞回合,再收口提交新指令。
                    if thinking { state.interruptActiveModelCall() }
                    voice.finishCurrentUtterance()
                    resetUtterance()
                    phase = .thinking
                }
            } else {
                silenceStartedAt = now
            }
        } else if phase != .capturing {
            // 没在捕获真实说话:思考中保持"思考中"状态,否则回到"在听你说"。
            phase = thinking ? .thinking : .listening
        }
    }
}
