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

        // 状态机:「我在听」窗口内一直没有效语音活动 → 复位 armed,回到干净待机
        // (下次喊唤醒词/开口会重新响铃、重开窗口)。这是"我在听 →(无有效内容)→ 待机"那条变体的落地。
        if state.voiceListeningArmed,
           now.timeIntervalSince(state.lastVoiceActivityAt) >= state.voiceListeningWindowSeconds {
            state.voiceListeningArmed = false
        }

        adaptiveVAD.observe(level: level, isCapturingSpeech: hasCapturedSpeech || voice.isSpeakingOrQueued)

        // 灵枢正在回应（TTS）：**不再停麦**——靠 AEC(setVoiceProcessingEnabled)消掉灵枢自己的声音,
        // 麦克风持续收音、随时判定主人是否插话。只在【确认是真指令】(持续真实说话 ≥0.7s)才打断 TTS,
        // 短促噪音/回声(AEC 残留)忽略。打断后不 resetUtterance:让识别继续累积主人这句,收口正常提交。
        if voice.isSpeakingOrQueued {
            phase = .responding
            if !voice.isRecording {   // 保持麦克风常开(不停),以便边播边听
                LingShuPerceptionActions.resumeListening(state: state, voice: voice, perceptionGateway: perceptionGateway)
            }
            // 电平打断只在 AEC 真生效时做:没有 AEC 时灵枢自己 TTS 的回声电平就常超过打断门槛(实测 0.22~0.25 > 0.20),
            // 会自己打断自己。半双工下不靠电平 barge-in(发声中根本不接受插话,见 handleVoiceTranscript 的硬闸)。
            if voice.isVoiceProcessingActive, level > adaptiveVAD.bargeInThreshold {
                if let started = bargeInStartedAt {
                    if now.timeIntervalSince(started) > 0.7 {
                        voice.stopSpeaking()   // 主人确实在说话 → 打断灵枢的 TTS,接住主人这句
                        lingShuControlLog("voice/barge: VAD电平打断成功 lvl=\(String(format: "%.2f", level)) thr=\(String(format: "%.2f", adaptiveVAD.bargeInThreshold))")
                        bargeInStartedAt = nil
                        hasCapturedSpeech = true   // 已在捕获主人这句(不清空,收口后提交)
                        silenceStartedAt = nil
                        phase = .capturing
                    }
                } else {
                    bargeInStartedAt = now
                    // 诊断:电平已过打断门槛、开始计时(需持续 0.7s 才真打断)。看不到这行=电平根本没到门槛
                    // (AEC 把声音连同回声一起压没了 / 门槛太高 / inputLevel 没更新)→ Path A 失灵。
                    lingShuControlLog("voice/barge: VAD疑似插话起算 lvl=\(String(format: "%.2f", level)) thr=\(String(format: "%.2f", adaptiveVAD.bargeInThreshold)) noiseFloor=\(String(format: "%.2f", adaptiveVAD.noiseFloor))")
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
