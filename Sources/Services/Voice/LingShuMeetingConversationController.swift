import Foundation

/// 会议端到端对话控制器(S1)——把"听会议"接上"灵枢应答":
/// 系统音频(`LingShuSystemAudioCapture`,听到的是会议里**别人**的声音)→ 会议 ASR(`LingShuMeetingASR`)→
/// 检测对方一段话说完(转写稳定一小段时间)→ 当成一次输入喂给 agent 主循环(全能力:可对话、可演示 PPT)→
/// 回复经 TTS 播出。配上虚拟麦克风(自建签名 HAL 驱动)后,这段 TTS 就回到了会议里,对方能听见。
///
/// 设计要点:
/// - **输入是系统音频不是麦克风**(与极简语音模式 `LingShuVoiceCallController` 的区别);采集已 `excludesCurrentProcessAudio`,
///   灵枢自己的 TTS 不会被当成"对方发言"回灌(无自听回环)。
/// - **灵枢说话/思考时不收口新轮次**(`hasActiveModelCall`/`isSpeakingOrQueued`),避免把自己接话打断、或边说边抢答。
/// - 复用 agent 主入口 `submitTextInput(source:.meeting)` → 自动获得计划/产出物/PPT/记忆等全部能力。
@MainActor
final class LingShuMeetingConversationController: ObservableObject {
    enum Phase: Equatable { case idle, listening, capturing, responding }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?

    private weak var state: LingShuState?
    private weak var voice: VoiceIOManager?
    private var loopTask: Task<Void, Never>?

    /// 对方停顿多久算"一句说完"(可收口提交)。
    private let silenceHold: TimeInterval = 1.2
    private let tickInterval: UInt64 = 200_000_000   // 200ms 轮询转写增长

    /// 已提交给 agent 的转写长度(只把**新增**的那段当本轮发言,不重复提交)。
    private var submittedLength = 0
    private var lastTranscriptLength = 0
    private var lastGrowthAt = Date()

    var isActive: Bool { loopTask != nil }

    func start(state: LingShuState, voice: VoiceIOManager) {
        guard loopTask == nil else { return }
        self.state = state
        self.voice = voice
        lastError = nil
        submittedLength = 0
        lastTranscriptLength = 0
        lastGrowthAt = Date()

        // 系统音频 → 会议 ASR(与 meeting_start_capture 同一套管线)。
        LingShuSystemAudioCapture.shared.onPCMChunk = { samples, sampleRate in
            LingShuMeetingASR.shared.appendPCM(samples, sampleRate: sampleRate)
        }
        Task { @MainActor [weak self] in
            do {
                try await LingShuSystemAudioCapture.shared.start()
                LingShuMeetingASR.shared.start()
                self?.phase = .listening
            } catch {
                self?.lastError = "系统音频采集启动失败(多半缺屏幕录制权限):\(error.localizedDescription)"
                self?.stop()
            }
        }
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        LingShuSystemAudioCapture.shared.onPCMChunk = nil
        Task { await LingShuSystemAudioCapture.shared.stop() }
        LingShuMeetingASR.shared.stop()
        phase = .idle
    }

    private func runLoop() async {
        while !Task.isCancelled {
            tick()
            try? await Task.sleep(nanoseconds: tickInterval)
        }
    }

    private func tick() {
        guard let state, let voice else { return }
        // 自主演示中:大脑在长回合里一直 hasActiveModelCall=真。此时仍要捕获对方的**现场提问**,
        // 改为 interject 注入当前自主循环(下方收口处),**不能丢**——这是"边讲边答"的关键。
        let autonomousPresenting = state.autonomousRun.phase == .running

        // 灵枢正在思考/说话且**非自主演示**:不收口,把当前转写"已读"指针跟到最新(等它说完再算新轮)。
        // 自主演示则**不**走这条短路——否则演示全程都在丢对方发言。
        if !autonomousPresenting, state.hasActiveModelCall || voice.isSpeakingOrQueued {
            phase = .responding
            let len = LingShuMeetingASR.shared.transcript.count
            submittedLength = max(submittedLength, len)
            lastTranscriptLength = len
            lastGrowthAt = Date()
            return
        }

        let transcript = LingShuMeetingASR.shared.transcript
        let len = transcript.count
        let now = Date()

        if len > lastTranscriptLength {
            lastTranscriptLength = len
            lastGrowthAt = now
            phase = .capturing
            return
        }

        // 转写不再增长 + 有未提交的新内容 + 稳定够久 → 一句说完,收口提交给 agent。
        let pending = len - submittedLength
        if pending > 0, now.timeIntervalSince(lastGrowthAt) >= silenceHold {
            let utterance = meetingUtterance(from: transcript, since: submittedLength)
            submittedLength = len
            if utterance.count >= 2 {   // 太短(语气词/噪音误转)不打扰
                phase = .responding
                if autonomousPresenting {
                    // 自主演示中:作为现场提问注入当前自主循环(步骤边界采纳)→ 答完接着讲,同一个大脑。
                    state.injectMeetingQuestion(utterance)
                } else {
                    // 非演示态:照旧起一轮新的主会话应答。
                    _ = state.submitTextInput(utterance, source: .meeting)
                }
            }
        } else if phase != .capturing {
            phase = .listening
        }
    }

    /// 取转写自 `since` 之后的新增片段(按字符位置切,SFSpeechRecognizer 给的是累积串)。
    private func meetingUtterance(from transcript: String, since: Int) -> String {
        guard since >= 0, since < transcript.count else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        let start = transcript.index(transcript.startIndex, offsetBy: since)
        return String(transcript[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
