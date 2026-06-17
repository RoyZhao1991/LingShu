@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

/// 轮换识别请求时复用的回调集合（onAudioChunk 不在内，它留在常驻 tap 里）。
struct VoiceSpeechCallbacks {
    let onText: @MainActor (String) -> Void
    let onFinal: (@MainActor (String) -> Void)?
    let onInterruption: (@MainActor () -> Void)?
    let onResult: (@MainActor (LingShuVoiceTranscriptionResult) -> Void)?
}

/// 当前识别请求的线程安全持有器。音频 tap 在专用音频线程上调用 `append`，
/// 主线程在每句结束时 `swap` 成新请求；用锁守一下保证 Swift 6 并发安全。
/// 这样音频引擎与 tap 全程常驻，只轮换轻量的识别请求，消除"每句拆引擎重启"的卡顿与丢音。
final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    func swap(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        current = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let request = current; lock.unlock()
        request?.append(buffer)
    }
}

@MainActor
final class VoiceIOManager: ObservableObject {
    @Published var isRecording = false {
        didSet {
            if !isRecording { inputLevel = 0 }
        }
    }
    @Published var isSpeaking = false {
        didSet {
            guard isSpeaking != oldValue else { return }
            if isSpeaking {
                startOutputMetering()
            } else {
                stopOutputMetering()
                lastSpeechEndedAt = Date()   // 记录刚说完的时刻:其后短暂冷却内忽略麦克风(吃掉 TTS 回声尾巴)
                // **整段发声真正结束**(没有后续排队句)时,才丢弃麦克风累积的转写(那是 TTS 回声)。
                // 句间间隙(isSpeakingOrQueued 仍 true)**不清**——否则会把用户的打断「灵枢」/接话也清掉
                // (实测:之前每次切换都清,导致回应中喊灵枢打不断、第一轮后再说话进了"我在听"却没提交)。
                if !isSpeakingOrQueued {
                    transcript = ""
                    lastPartialAt = .distantPast
                }
            }
        }
    }
    /// 最近一次 TTS 发声结束的时刻;其后 `echoCooldownSeconds` 内的非唤醒词麦克风输入按回声忽略。
    var lastSpeechEndedAt: Date = .distantPast
    /// 发声结束后的回声冷却时长(秒):吃掉 TTS 尾音回声,避免被当成新输入。
    let echoCooldownSeconds: TimeInterval = 1.0
    @Published var transcript = ""
    @Published var inputStatusMessage = "收音待机"
    @Published var outputStatusMessage = "发声待机"
    @Published var statusMessage = "语音待机"
    /// 云端男声降级原因（缺凭据/请求失败等）。**持久**保留直到下一次云端合成成功才清空——
    /// outputStatusMessage 在每句播完后会被重置成待机态，告警一闪就没；这个标记不闪，底部告警条据此常驻。
    @Published var cloudVoiceDegradedReason: String?
    @Published var transcriptionProvider = LingShuVoiceTranscriptionProviderDescriptor.appleSpeech
    @Published private(set) var embeddedASRStatus = LingShuEmbeddedASRRuntimeLocator.senseVoiceSherpaONNXStatus()
    @Published private(set) var embeddedTTSStatus = LingShuEmbeddedTTSRuntimeLocator.sherpaONNXTTSStatus()
    @Published var speechOutputProvider = LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS
    @Published var speechOutputEndpoint = LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS.defaultEndpoint
    @Published var speechOutputAPIKey = ""
    @Published var speechPersona = LingShuSpeechPersona.calmJarvisMale
    /// 实时输入电平 0...1（麦克风 RMS），供极简模式的输入波形使用。
    @Published var inputLevel: Float = 0
    /// 实时输出电平 0...1（TTS 播放音量计），供极简模式的输出波形使用。
    @Published var outputLevel: Float = 0
    /// 麦克风没进音的可见告警(权限未授权/设备问题致"语音无反应"时,别再静默失败——浮出一句话让用户能修)。
    @Published var micSilentWarning: String?
    /// 最近一次音频 tap 真收到缓冲的时刻(看门狗据此判"引擎在跑但麦克风没进音")。
    var lastInputBufferAt: Date = .distantPast
    /// 静音收口:最近一次 ASR partial 更新的时刻。partial 文本静默超过 `silenceFinalizeSeconds`
    /// 就**强制把当前转写当一句收口提交**,不傻等 SFSpeech 的 isFinal(它常迟迟不来 → 卡在"我在听"不进思考)。
    var lastPartialAt: Date = .distantPast
    /// 静音收口阈值(秒);<=0 关闭。默认 2s = 说完停顿 2 秒即转入思考。
    var silenceFinalizeSeconds: TimeInterval = 2.0
    private var micWatchdogTask: Task<Void, Never>?
    /// 是否启用系统语音处理(AEC)。VPIO 在某些机器/设备组合下会把麦克风弄哑(引擎在跑却零进音);
    /// 看门狗发现没进音会把它关掉重试一次(宁可没回声消除,也要麦克风能用)。
    /// **持久**:一旦在本机判定 VPIO 坏麦,下次直接从一开始就不开它,省掉每次 3.5s 自愈延迟。
    private var preferVoiceProcessing = !UserDefaults.standard.bool(forKey: "lingshu.voiceProcessingBroken")
    /// 重开识别用(看门狗自愈时复用同一组回调,不必让上层重新调用)。
    private var restartRecognition: (@MainActor () -> Void)?

    var outputMeterTask: Task<Void, Never>?

    private let audioEngine = AVAudioEngine()
    /// 语音语言(国际化,中/英)。改它会重建 ASR 识别器,并让 TTS 选对应语种嗓音(英文走本机英文嗓)。持久化。
    @Published var voiceLanguage: LingShuVoiceLanguage = VoiceIOManager.persistedVoiceLanguage {
        didSet {
            guard voiceLanguage != oldValue else { return }
            UserDefaults.standard.set(voiceLanguage.rawValue, forKey: "lingshu.voiceLanguage")
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: voiceLanguage.asrLocale))
        }
    }
    static var persistedVoiceLanguage: LingShuVoiceLanguage {
        LingShuVoiceLanguage(rawValue: UserDefaults.standard.string(forKey: "lingshu.voiceLanguage") ?? "zh") ?? .chinese
    }
    // 识别器随语言可重建(不再 let):初始 locale 取持久化语言。
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: VoiceIOManager.persistedVoiceLanguage.asrLocale))
    let speechSynthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// 当前识别请求的线程安全持有器：音频 tap 始终往"当前"请求灌音频，
    /// 每句结束只轮换请求/任务（不拆引擎、不拆 tap），消除每句重启的卡顿与丢音。
    let recognitionRequestBox = RecognitionRequestBox()
    /// 轮换识别请求时复用的回调（onAudioChunk 留在常驻 tap 里，不在此存）。
    private var speechCallbacks: VoiceSpeechCallbacks?
    private var embeddedASRProcess: Process?
    private var embeddedASROutputHandle: FileHandle?
    private var embeddedASRLineBuffer = ""
    var speechAudioPlayer: AVAudioPlayer?
    /// 真流式 PCM 播放器（数据网关 /stream 边收边播时使用）；打断时一并 stop。
    var activeStreamingPlayer: LingShuStreamingPCMPlayer?
    var activeSpeechTask: Task<Void, Never>?
    /// 发声「代次」:每次 `speak(_:)` 递增。任何更晚的发声(或降级)都会让先前在飞的云端/本机音频「过期」——
    /// 过期音频一律不再起播、也不再翻转 `isSpeaking`,根治云端 TTS 与降级本机语音叠在一起(双声线)。
    var speechGeneration: Int = 0
    /// 分句早读队列：流式回复的整句按到达顺序排队播报；
    /// 排队/排空逻辑在 VoiceIOManager+SpeechQueue.swift。
    var speechQueue: [String] = []
    var speechQueueDrainTask: Task<Void, Never>?
    /// 增量无缝流式发声:句子陆续到达→并行预取各句 TTS WAV→按句序背靠背灌进**一个持续 PCM 播放器**,无缝顺序播放。
    /// 逻辑在 VoiceIOManager+StreamingSpeechQueue.swift。比逐句 speakQueued(每句等一次完整网络往返)流畅。
    var streamingSpeechPlayer: LingShuStreamingPCMPlayer?
    var streamingSpeechDrainTask: Task<Void, Never>?
    var streamingSpeechTexts: [Int: String] = [:]            // 句序号→文本(drainer 按窗口预取,不一上来全发)
    var streamingSpeechPrefetch: [Int: Task<Data, Error>] = [:]
    var streamingSpeechNextIndex = 0     // 下一句分配的序号(feed 时递增)
    var streamingSpeechNextToPlay = 0    // drainer 下一个要播的序号(保证按句序无缝)
    var streamingSpeechEnded = false     // 已收到结束信号(没有更多句子)
    var streamingSpeechFirstSampleRate: Double = 0           // 首段采样率;后续段不一致则跳过(防音高/噪音)
    var streamingSpeechConfig: (provider: LingShuSpeechOutputProviderDescriptor, endpoint: String, apiKey: String, persona: LingShuSpeechPersona)?
    let bundledRuntimeConfig = LingShuBundledRuntimeConfig()
    let credentialStore = LingShuCredentialStore()

    var availableTranscriptionProviders: [LingShuVoiceTranscriptionProviderDescriptor] {
        LingShuVoiceTranscriptionProviderDescriptor.recommendedChineseProviders.map { provider in
            guard provider.id == LingShuEmbeddedASRRuntimeLocator.senseVoiceProviderID else {
                return provider
            }

            return provider.applyingRuntimeAvailability(embeddedASRStatus)
        }
    }

    var availableSpeechOutputProviders: [LingShuSpeechOutputProviderDescriptor] {
        LingShuSpeechOutputProviderDescriptor.recommendedProviders.map { provider in
            guard provider.id == LingShuEmbeddedTTSRuntimeLocator.sherpaTTSProviderID else {
                return provider
            }

            return provider.applyingRuntimeAvailability(embeddedTTSStatus)
        }
    }

    var availableSpeechPersonas: [LingShuSpeechPersona] {
        LingShuSpeechPersona.recommendedPersonas
    }

    init() {
        refreshEmbeddedASRRuntimeStatus()
        refreshEmbeddedTTSRuntimeStatus()
        setOutputStatus(outputStandbyStatus(for: speechOutputProvider))
    }

    func refreshEmbeddedASRRuntimeStatus() {
        embeddedASRStatus = LingShuEmbeddedASRRuntimeLocator.senseVoiceSherpaONNXStatus()

        if transcriptionProvider.id == LingShuEmbeddedASRRuntimeLocator.senseVoiceProviderID {
            if let refreshed = availableTranscriptionProviders.first(where: { $0.id == transcriptionProvider.id }),
               refreshed.isRuntimeAvailable {
                transcriptionProvider = refreshed
            } else {
                transcriptionProvider = .appleSpeech
                setInputStatus("SenseVoice 未就绪，已回退 Apple Speech")
            }
        }
    }

    func refreshEmbeddedTTSRuntimeStatus() {
        embeddedTTSStatus = LingShuEmbeddedTTSRuntimeLocator.sherpaONNXTTSStatus()

        if speechOutputProvider.id == LingShuEmbeddedTTSRuntimeLocator.sherpaTTSProviderID {
            if let refreshed = availableSpeechOutputProviders.first(where: { $0.id == speechOutputProvider.id }) {
                speechOutputProvider = refreshed
            }

            if embeddedTTSStatus.isAvailable {
                setOutputStatus("本地男声待机")
            } else {
                setOutputStatus("本地男声未就绪，系统发声兜底")
            }
        }
    }

    func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        setInputStatus("正在请求语音权限")

        if transcriptionProvider.kind == .senseVoiceSherpaONNX {
            refreshEmbeddedASRRuntimeStatus()
            AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
                Task { @MainActor in
                    completion(microphoneAllowed)
                }
            }
            return
        }

        let speechAuthorizationHandler: @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = { speechStatus in
            let microphoneAuthorizationHandler: @Sendable (Bool) -> Void = { microphoneAllowed in
                Task { @MainActor in
                    let allowed = speechStatus == .authorized && microphoneAllowed
                    completion(allowed)
                }
            }

            AVCaptureDevice.requestAccess(for: .audio, completionHandler: microphoneAuthorizationHandler)
        }

        SFSpeechRecognizer.requestAuthorization(speechAuthorizationHandler)
    }

    func startRecognition(
        onText: @escaping @MainActor (String) -> Void,
        onFinal: (@MainActor (String) -> Void)? = nil,
        onAudioChunk: (@MainActor (LingShuAudioStreamPacket) -> Void)? = nil,
        onInterruption: (@MainActor () -> Void)? = nil,
        onResult: (@MainActor (LingShuVoiceTranscriptionResult) -> Void)? = nil
    ) throws {
        refreshEmbeddedASRRuntimeStatus()
        guard transcriptionProvider.isRuntimeAvailable else {
            transcriptionProvider = .appleSpeech
            setInputStatus("语音模型未就绪，已回退 Apple Speech")
            return try startRecognition(
                onText: onText,
                onFinal: onFinal,
                onAudioChunk: onAudioChunk,
                onInterruption: onInterruption,
                onResult: onResult
            )
        }

        stopRecognition()

        if transcriptionProvider.kind == .senseVoiceSherpaONNX {
            try startEmbeddedSenseVoiceRecognition(
                onText: onText,
                onFinal: onFinal,
                onResult: onResult
            )
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw LingShuVoiceError.speechRecognizerUnavailable
        }

        let inputNode = audioEngine.inputNode
        // 诊断:点名当前麦克风/语音识别授权态(0=未决 1=受限 2=拒绝 3=已授权)——
        // "引擎在跑但 tap 不进音"最常见真因=授权没真给(或签名变了 TCC 失效),这行直接坐实。
        lingShuControlLog("voice/perm: speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        // 开启系统语音处理(AEC 回声消除):TTS 播放时麦克风**不再自听灵枢自己的声音**,
        // 从而可在灵枢说话时**持续收音**、随时听到主人插话并打断(barge-in)。
        // 失败/不支持则退回无 AEC(识别仍可用,只是说话时不宜常开麦)。必须在引擎启动前设、会改输入格式。
        if preferVoiceProcessing, !inputNode.isVoiceProcessingEnabled {
            try? inputNode.setVoiceProcessingEnabled(true)
        } else if !preferVoiceProcessing, inputNode.isVoiceProcessingEnabled {
            try? inputNode.setVoiceProcessingEnabled(false)   // 自愈:VPIO 把麦克风弄哑了,关掉 AEC 重来
        }
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            throw LingShuVoiceError.audioInputUnavailable
        }

        // 引擎与 tap 只安装一次、全程常驻；tap 往 box 灌音频（每句只轮换请求，不动引擎）。
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: recordingFormat,
            block: makeRecognitionAudioTap(box: recognitionRequestBox, onAudioChunk: onAudioChunk)
        )
        audioEngine.prepare()
        try audioEngine.start()

        speechCallbacks = VoiceSpeechCallbacks(onText: onText, onFinal: onFinal, onInterruption: onInterruption, onResult: onResult)
        restartRecognition = { [weak self] in
            try? self?.startRecognition(onText: onText, onFinal: onFinal, onAudioChunk: onAudioChunk, onInterruption: onInterruption, onResult: onResult)
        }
        isRecording = true
        transcript = ""
        setInputStatus(speechRecognizer.supportsOnDeviceRecognition ? "正在听（本机）" : "正在听")
        armSpeechRecognition()
        startMicAudioWatchdog()
    }

    /// 麦克风进音看门狗:引擎"启动成功"≠真有音频流(授权未真给/签名变了 TCC 失效/设备问题时,
    /// 引擎在跑但 tap 一个缓冲都不回 → "语音无反应"还**静默无错**)。3.5s 内没收到任何音频缓冲就**浮出可见告警**,
    /// 别让用户对着没反应的麦克风干等还不知道为什么。收到音频会自动清掉告警(见 tap)。
    private func startMicAudioWatchdog() {
        micWatchdogTask?.cancel()
        let startedAt = Date()
        micWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.isRecording, !Task.isCancelled else { return }
            guard self.lastInputBufferAt < startedAt else { return }   // 进音正常,无事
            let speech = SFSpeechRecognizer.authorizationStatus().rawValue
            let mic = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
            // **自愈**:权限都给了(mic/speech=3)却零进音,八成是 VPIO(AEC)把麦克风弄哑 → 关掉它重开一次。
            if mic == 3, speech == 3, self.preferVoiceProcessing {
                self.preferVoiceProcessing = false
                UserDefaults.standard.set(true, forKey: "lingshu.voiceProcessingBroken")   // 持久:下次直接不开 VPIO
                lingShuControlLog("voice/watchdog: 3.5s 无音频(mic=3 speech=3)→ 关 VPIO 重开识别自愈")
                self.stopRecognition()
                self.restartRecognition?()
                return
            }
            // 关了 VPIO 还是没进音,或权限确实没给 → 浮出可见告警,别静默。
            let denied = mic != 3 || speech != 3
            let msg = denied
                ? "麦克风/语音识别**没授权**(系统设置 › 隐私与安全性 › 麦克风 + 语音识别,把灵枢打开,再重开通话)"
                : "麦克风收不到声音(已关回声消除仍无进音,可能输入设备异常/被别的录音 App 独占)"
            self.micSilentWarning = msg
            self.setInputStatus("⚠️ " + msg)
            lingShuControlLog("voice/watchdog: 仍无音频,mic=\(mic) speech=\(speech) VPIO=\(self.preferVoiceProcessing) → 告警:\(msg)")
        }
    }

    /// 轮换识别请求：每句结束只换一个轻量请求/任务，引擎与 tap 不动——
    /// 消除"每句重启引擎 + 450ms 空档"造成的卡顿和丢音，续听无缝。
    private func armSpeechRecognition() {
        guard isRecording, let speechRecognizer, let callbacks = speechCallbacks else { return }

        recognitionTask?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request
        recognitionRequestBox.swap(request)

        recognitionTask = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let recognizedText = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil

            Task { @MainActor in
                // 身份闸：只处理"当前"请求的回调；轮换后旧任务的迟到回调（含取消错误）一律忽略，
                // 避免误触发整体停止把常驻引擎拆掉。
                guard let self, self.isRecording, self.recognitionRequest === request else { return }

                if let recognizedText {
                    let wasEmpty = self.transcript.isEmpty
                    let transcription = self.makeTranscriptionResult(text: recognizedText, isFinal: isFinal)
                    self.transcript = transcription.text
                    self.lastPartialAt = Date()   // 记录最近 partial 时间(静音收口判据)
                    callbacks.onText(transcription.text)
                    callbacks.onResult?(transcription)
                    // 诊断:ASR 真出了转写(本句首个 partial + 每个 final)——定位"麦克风有进音但没识别出来"还是"识别了没提交"。
                    if isFinal || wasEmpty {
                        lingShuControlLog("voice/asr: 听到「\(recognizedText.prefix(24))」isFinal=\(isFinal)")
                    }

                    if isFinal {
                        callbacks.onFinal?(transcription.text)
                        self.transcript = ""              // 收口后清空,避免静音判据用旧文本重复触发
                        self.lastPartialAt = .distantPast
                        self.armSpeechRecognition()       // 无缝轮换到下一句
                    }
                }

                if hasError {
                    lingShuControlLog("voice/asr: 错误 \(String(describing: error).prefix(70))")
                    self.stopRecognition()
                    self.setInputStatus("语音识别已中断")
                    if !isFinal {
                        callbacks.onInterruption?()
                    }
                }
            }
        }
    }

    /// 静音收口判定(由音频 tap 每 ~50ms 在主线程调):有未收口的转写、且 partial 静默超过阈值 → 强制收口。
    /// 这就是"说完停 2 秒就进入思考"——不傻等 SFSpeech 的 isFinal(连续识别下它常迟迟不来)。
    func evaluateUtteranceSilence(now: Date = Date()) {
        guard isRecording, silenceFinalizeSeconds > 0,
              !transcript.isEmpty, lastPartialAt != .distantPast,
              now.timeIntervalSince(lastPartialAt) >= silenceFinalizeSeconds else { return }
        forceFinalizeUtterance()
    }

    /// 强制把当前 partial 转写当一句 final 提交(走 onResult,isFinal=true → 主线程转入思考),并轮换识别接下一句。
    private func forceFinalizeUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let callbacks = speechCallbacks else { return }
        transcript = ""
        lastPartialAt = .distantPast
        lingShuControlLog("voice/asr: 静音 \(String(format: "%.0f", silenceFinalizeSeconds))s 强制收口「\(text.prefix(24))」→ 转入思考")
        callbacks.onResult?(makeTranscriptionResult(text: text, isFinal: true))
        callbacks.onFinal?(text)
        armSpeechRecognition()
    }

    private func makeTranscriptionResult(text: String, isFinal: Bool) -> LingShuVoiceTranscriptionResult {
        let normalizedText = LingShuVoiceTranscriptNormalizer.normalize(text)
        return .init(
            text: normalizedText,
            isFinal: isFinal,
            confidence: nil,
            provider: transcriptionProvider,
            intentHint: normalizedText.isEmpty ? nil : "speech-to-text",
            timestamp: Date()
        )
    }

    private func startEmbeddedSenseVoiceRecognition(
        onText: @escaping @MainActor (String) -> Void,
        onFinal: (@MainActor (String) -> Void)?,
        onResult: (@MainActor (LingShuVoiceTranscriptionResult) -> Void)?
    ) throws {
        let status = embeddedASRStatus
        guard status.isAvailable,
              let runtimePath = status.runtimePath,
              let modelPath = status.modelPath,
              let tokensPath = status.tokensPath,
              let vadModelPath = status.vadModelPath else {
            throw LingShuVoiceError.embeddedRuntimeUnavailable(status.diagnosticSummary)
        }

        let runtimeURL = URL(fileURLWithPath: runtimePath)
        let process = Process()
        process.executableURL = runtimeURL
        process.currentDirectoryURL = runtimeURL.deletingLastPathComponent()
        process.arguments = [
            "--silero-vad-model=\(vadModelPath)",
            "--tokens=\(tokensPath)",
            "--sense-voice-model=\(modelPath)",
            "--sense-voice-language=zh",
            "--sense-voice-use-itn=true",
            "--num-threads=2",
            "--provider=cpu",
            "--print-args=false"
        ]

        var environment = ProcessInfo.processInfo.environment
        let libDirectory = runtimeURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib", isDirectory: true)
        let existingLibraryPath = environment["DYLD_LIBRARY_PATH"] ?? ""
        environment["DYLD_LIBRARY_PATH"] = existingLibraryPath.isEmpty
            ? libDirectory.path
            : "\(libDirectory.path):\(existingLibraryPath)"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let provider = transcriptionProvider
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor in
                self?.consumeEmbeddedASROutput(
                    chunk,
                    provider: provider,
                    onText: onText,
                    onFinal: onFinal,
                    onResult: onResult
                )
            }
        }

        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.consumeEmbeddedASRDiagnostic(chunk)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.embeddedASRProcess === process else { return }
                self.embeddedASRProcess = nil
                self.embeddedASROutputHandle = nil
                self.isRecording = false
                self.setInputStatus(process.terminationStatus == 0 ? "本地收音已停止" : "本地收音已中断")
            }
        }

        do {
            try process.run()
        } catch {
            throw LingShuVoiceError.embeddedRuntimeLaunchFailed(error.localizedDescription)
        }

        embeddedASRProcess = process
        embeddedASROutputHandle = outputHandle
        embeddedASRLineBuffer = ""
        isRecording = true
        transcript = ""
        setInputStatus("正在听（SenseVoice）")
    }

    private func consumeEmbeddedASROutput(
        _ chunk: String,
        provider: LingShuVoiceTranscriptionProviderDescriptor,
        onText: @escaping @MainActor (String) -> Void,
        onFinal: (@MainActor (String) -> Void)?,
        onResult: (@MainActor (LingShuVoiceTranscriptionResult) -> Void)?
    ) {
        embeddedASRLineBuffer += chunk
        let parts = embeddedASRLineBuffer.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !parts.isEmpty else { return }

        let endedWithNewline = embeddedASRLineBuffer.last?.isNewline == true
        let completeLines = endedWithNewline ? parts : parts.dropLast()
        embeddedASRLineBuffer = endedWithNewline ? "" : String(parts.last ?? "")

        for line in completeLines {
            let text = extractEmbeddedTranscript(from: String(line))
            guard !text.isEmpty else { continue }

            let result = LingShuVoiceTranscriptionResult(
                text: text,
                isFinal: true,
                confidence: nil,
                provider: provider,
                intentHint: "local-sensevoice",
                timestamp: Date()
            )
            transcript = result.text
            onText(result.text)
            onResult?(result)
            onFinal?(result.text)
        }
    }

    private func consumeEmbeddedASRDiagnostic(_ chunk: String) {
        if chunk.localizedCaseInsensitiveContains("error") || chunk.localizedCaseInsensitiveContains("failed") {
            setInputStatus("SenseVoice 运行异常")
        }
    }

    private func extractEmbeddedTranscript(from line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let ignoredPrefixes = [
            "Started!",
            "Please",
            "If you",
            "Use",
            "Creating",
            "Created",
            "Started",
            "Done",
            "Press Ctrl"
        ]
        if ignoredPrefixes.contains(where: { cleaned.hasPrefix($0) }) {
            return ""
        }

        if let colonRange = cleaned.range(of: ":") {
            let prefix = cleaned[..<colonRange.lowerBound].lowercased()
            if ["text", "result", "recognized", "asr"].contains(where: { prefix.contains($0) }) {
                cleaned = String(cleaned[colonRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return LingShuVoiceTranscriptNormalizer.normalize(cleaned)
    }

    /// 结束当前这一句：触发识别给出最终结果（isFinal），但不拆掉麦克风管线。
    /// 连续对话模式的 VAD 静音断句用它把一句话收口并自动提交。
    func finishCurrentUtterance() {
        guard isRecording else { return }
        recognitionRequest?.endAudio()
    }

    /// 立即停止 TTS 播报（用户打断时调用）；同时清空分句早读队列。
    func stopSpeaking() {
        cancelStreamingSpeech()   // 同时停掉增量流式发声(打断/新回合)
        speechQueue.removeAll()
        speechQueueDrainTask?.cancel()
        speechQueueDrainTask = nil
        activeSpeechTask?.cancel()
        speechAudioPlayer?.stop()
        activeStreamingPlayer?.stop()
        activeStreamingPlayer = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    func stopRecognition() {
        embeddedASROutputHandle?.readabilityHandler = nil
        if let embeddedASRProcess, embeddedASRProcess.isRunning {
            embeddedASRProcess.terminate()
        }
        embeddedASRProcess = nil
        embeddedASROutputHandle = nil
        embeddedASRLineBuffer = ""

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequestBox.swap(nil)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        speechCallbacks = nil
        isRecording = false
        setInputStatus(transcript.isEmpty ? "收音待机" : "语音已转写")
    }

    func markInputError(_ message: String) {
        setInputStatus(message)
    }

    private func setInputStatus(_ message: String) {
        inputStatusMessage = message
        refreshOverallStatus()
    }

    func setOutputStatus(_ message: String) {
        outputStatusMessage = message
        refreshOverallStatus()
    }

    private func refreshOverallStatus() {
        if isRecording || inputStatusMessage.contains("权限") || inputStatusMessage.contains("中断") || inputStatusMessage.contains("失败") {
            statusMessage = inputStatusMessage
        } else if isSpeaking {
            statusMessage = outputStatusMessage
        } else {
            statusMessage = "语音待机"
        }
    }

}
