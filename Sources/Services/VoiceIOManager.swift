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
    /// AEC(系统语音处理/VPIO)当前是否真生效。**这是能否在灵枢说话时听清主人插话(barge-in)的物理前提**:
    /// 为 true 时麦克风里灵枢自己的 TTS 已被消掉,可放心做唤醒词/电平打断;为 false 时麦克风听到的全是自己,
    /// 任何打断判据都分不清"自己"和"主人"(实测自我介绍念到"灵枢"会打断自己),必须半双工(发声中不听)。
    var isVoiceProcessingActive: Bool { audioEngine.inputNode.isVoiceProcessingEnabled }
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
    /// `AVAudioEngineConfigurationChange` 观察者:外接/虚拟音频设备变更会让引擎自动停(苹果要求 app 自行重启,
    /// 否则就一直停=麦克风死)。监听到就有界自动重启,自愈"引擎启动后即死"。
    private var configChangeObserver: NSObjectProtocol?
    /// 配置变更自动重启的连续计数(有界,防虚拟音频软件持续churn时死循环重启)。
    private var configRestartAttempts = 0
    /// 静默检测任务:引擎在跑但 tap 长时间收不到缓冲 → 浮出可见告警(只提示,**绝不关 AEC**——
    /// 旧看门狗就是误关 AEC 才被删的)。根治"麦克风被录屏/虚拟音频软件占用 / VPIO 绑到畸形聚合设备 →
    /// 喊灵枢无反应却一直静默显示待机中"。
    private var micSilenceMonitor: Task<Void, Never>?
    /// 静音收口:最近一次 ASR partial 更新的时刻。partial 文本静默超过 `silenceFinalizeSeconds`
    /// 就**强制把当前转写当一句收口提交**,不傻等 SFSpeech 的 isFinal(它常迟迟不来 → 卡在"我在听"不进思考)。
    var lastPartialAt: Date = .distantPast
    /// 静音收口阈值(秒);<=0 关闭。默认 2s = 说完停顿 2 秒即转入思考。
    var silenceFinalizeSeconds: TimeInterval = 2.0
    /// 音频静默收口(2026-06-19,修"嘈杂/连续识别下指令永不收口"):最近一次"主人在出声"(电平过说话门槛)的时刻。
    /// 与 `lastPartialAt` 互补——背景噪音会持续刷新 ASR partial 让 `lastPartialAt` 永不稳定、转写永不收口;
    /// 而**主人一旦停止出声(电平降下来)持续 `audioSilenceFinalizeSeconds`**,就强制收口,不被噪音 partial 拖住。
    var lastLoudInputAt: Date = .distantPast
    /// 主人停止出声多久(秒)就音频静默收口。3s = 与语音端点容忍一致(中途停顿 ≤3s 不切)。
    let audioSilenceFinalizeSeconds: TimeInterval = 3.0
    /// 判"主人正在出声"的电平门槛(近场说话通常 >0.12,环境底噪通常 <0.06)。
    let loudInputThreshold: Float = 0.10
    /// 系统语音处理(AEC/VPIO)**强制常开**(用户定调 2026-06-18)。系统音(ScreenCaptureKit)与麦克风
    /// (AVAudioEngine)是两条独立收音线路、互不冲突;AEC 是"灵枢说话时仍能听清主人插话(barge-in)"的
    /// **物理必要条件**,绝不再自动关。已删除原"发现没进音就关 VPIO 自愈"的看门狗——它会误杀 AEC
    /// (实测:VPIO 刚开的几秒还没开始出音频,就被判坏麦关掉,导致永远没有回声消除→灵枢自听自激)。
    private let preferVoiceProcessing = true

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
    /// **演示翻页预合成缓存**(按讲稿文本 key → 全部分段 + 已预合成的前几段任务):当前页念时,后台把下一页**前几段**
    /// WAV 先合成好;下一页发声命中即时起播(其余段播放时按窗口续取),消除翻页「处理中」停顿(云端 TTS 短句也要 3-4s 首包)。
    /// 只预合成前几段=并发可控、长讲稿也不爆。逻辑在 VoiceIOManager+PresentationPrefetch.swift。
    var presentationPrefetch: [String: (segs: [String], leadTasks: [Task<Data, Error>])] = [:]
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
        if !inputNode.isVoiceProcessingEnabled {
            try? inputNode.setVoiceProcessingEnabled(true)   // AEC 强制常开,绝不再自动关
        }
        // 注:实测 VPIO 无法从 App 侧控设备——钉内建麦(开前被重建聚合覆盖/开后把输入打死)、钉自建干净聚合
        // (开前被 VPIO 覆盖回 7ch/开后属性锁死 st=-10851)四种都不行。VPIO 固定用它自建的 VPAUAggregate
        // (从系统设备拼,会吸入 BlackHole/录屏等虚拟设备 → 畸形 7ch → 引擎死)。改靠下方"配置变更自动重启"
        // 自愈 + 静默检测告警 + 用户清理虚拟音频设备。详见 [[voice-aec-mic-troubleshooting]]。
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let hwInFormat = inputNode.inputFormat(forBus: 0)   // 硬件输入侧格式:0 声道/0Hz = VPIO 下硬件输入真死了
        let inputDeviceID = inputNode.auAudioUnit.deviceID   // 输入设备 id(对比开/不开 VPIO 是否换了设备)
        // 诊断:坐实"开 AEC 没麦克风音频"卡在哪——硬件输入格式是否有效 / 设备是否被换 / 引擎是否真在跑。
        lingShuControlLog("voice/aec: actualVPIO=\(inputNode.isVoiceProcessingEnabled) dev=\(inputDeviceID) HWin=\(String(format: "%.0f", hwInFormat.sampleRate))/\(hwInFormat.channelCount)ch tapFmt=\(String(format: "%.0f", recordingFormat.sampleRate))/\(recordingFormat.channelCount)ch")
        LingShuAudioRouting.logDeviceLandscape()   // 点名默认输入/输出+所有输入设备:坐实 dev 是不是聚合/虚拟设备
        guard recordingFormat.sampleRate > 0 else {
            throw LingShuVoiceError.audioInputUnavailable
        }

        // **VPIO 全双工接线(根治"开 AEC 就没麦克风音频")**:VoiceProcessing IO 输入与输出是同一个单元,
        // 输入侧靠**输出侧的渲染循环**来抽取。本引擎只收音(TTS 走独立播放器),输出图为空 → 输出不渲染 →
        // 单元不运转 → tap 一个缓冲都收不到(被误判"AEC 弄哑麦克风",实为接线缺输出驱动)。
        // 修法:把输入接到主混音器、主混音器输出音量置 0(不外放、不反馈),给输出一条要渲染的信号路径,
        // 单元就持续运转、麦克风输入正常流;AEC 的回声参考用**系统输出设备**(灵枢 TTS 在那播),与此无关。
        // **必须在装 tap 之前接好**(规范顺序:先建图、再 tap、最后 start)。
        if inputNode.isVoiceProcessingEnabled {
            let mixer = audioEngine.mainMixerNode   // 访问即实化 mixer→outputNode 连接
            mixer.outputVolume = 0                  // 静音:仅驱动渲染循环,绝不把麦克风外放(防啸叫)
            audioEngine.connect(inputNode, to: mixer, format: recordingFormat)
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
        lingShuControlLog("voice/engine: running=\(audioEngine.isRunning) mixerInputs=\(audioEngine.mainMixerNode.numberOfInputs)")

        speechCallbacks = VoiceSpeechCallbacks(onText: onText, onFinal: onFinal, onInterruption: onInterruption, onResult: onResult)
        isRecording = true
        transcript = ""
        setInputStatus(speechRecognizer.supportsOnDeviceRecognition ? "正在听（本机）" : "正在听")
        armSpeechRecognition()
        startMicSilenceMonitor()
        observeEngineConfigChange()
        // 旧看门狗已删除(用户定调 2026-06-18):它会在 VPIO 刚开、还没出音频的几秒内误判"坏麦"、**关掉 AEC** 并持久化,
        // 导致 AEC 永远开不起来→灵枢自听自激。AEC 是 barge-in 的物理必要条件,必须常开。
        // 新的静默检测(startMicSilenceMonitor)只**浮告警**、绝不动 AEC/设备,避开旧看门狗的坑。
    }

    /// 静默检测:引擎在跑但麦克风长时间(grace 期)收不到一帧 → 浮出可见告警,别让用户对着没反应的麦克风干等
    /// (喊灵枢无反应却一直显示"待机中"的根因之一:麦克风被录屏/会议/虚拟音频软件占用,或 VPIO 绑到了畸形聚合设备)。
    /// **只设告警,绝不关 AEC / 不动设备**(旧看门狗误关 AEC 才被删);进音后由 tap 回调清掉告警。
    private func startMicSilenceMonitor() {
        micSilenceMonitor?.cancel()
        let graceSeconds: TimeInterval = 8   // ≥VPIO 预热时间,避免刚开还没出音频就误报
        micSilenceMonitor = Task { @MainActor [weak self] in
            // 起步先等满 grace 期(给 VPIO/首帧留足时间),之后每 4s 复检。
            try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                let silentFor = Date().timeIntervalSince(self.lastInputBufferAt)
                // 只要"自以为在录"却 grace 期内一帧没进 → 告警。**不 gate engine.isRunning**:
                // 畸形聚合设备常让引擎 start 后立刻停(isRunning=false),那正是要告警的情况(否则被漏过)。
                if silentFor > graceSeconds {
                    let warning = "麦克风没在进音——可能被其他录音/录屏/会议/虚拟音频软件占用,或绑到了虚拟聚合设备。退出这些软件后,重新进入聆听/重启在岗。"
                    if self.micSilentWarning != warning {
                        self.micSilentWarning = warning
                        lingShuControlLog("voice/mic-silent: 自以为在录但 \(String(format: "%.0f", silentFor))s 无进音(engineRunning=\(self.audioEngine.isRunning)) → 浮告警(未动 AEC)")
                    }
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// 监听 `AVAudioEngineConfigurationChange`:外接/虚拟音频设备变更(如录屏软件动态建/拆聚合设备)会让 AVAudioEngine
    /// **自动停**——苹果要求 app 自行重启,否则引擎一直停=麦克风死("引擎启动后即死"的真因之一)。监听到就有界自动重启。
    /// 有界(连续 5 次内)防虚拟音频软件持续 churn 时无限重启;超界就停手,交给静默检测告警 + 用户清理设备。
    private func observeEngineConfigChange() {
        if let obs = configChangeObserver { NotificationCenter.default.removeObserver(obs); configChangeObserver = nil }
        configRestartAttempts = 0
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                let running = self.audioEngine.isRunning
                lingShuControlLog("voice/engine-config-change: 设备配置变更 → 引擎running=\(running) attempts=\(self.configRestartAttempts)")
                guard !running, self.configRestartAttempts < 5 else { return }
                self.configRestartAttempts += 1
                self.audioEngine.prepare()
                do {
                    try self.audioEngine.start()
                    lingShuControlLog("voice/engine-config-change: 自动重启引擎成功 running=\(self.audioEngine.isRunning)")
                } catch {
                    lingShuControlLog("voice/engine-config-change: 自动重启失败 \(error.localizedDescription)")
                }
            }
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
        // 发声中 / 刚发完的回声冷却窗口内,麦克风里几乎全是灵枢自己 TTS 的回声(AEC 没消干净时尤甚)。
        // **绝不**把这段回声"静音收口"成一句提交——否则灵枢把自己的话当指令→无谓"转入思考/处理中",
        // 播报一结束就卡在处理中(实测根因)。真正的主人插话由唤醒词/电平 barge-in 先掐掉 TTS,
        // 之后 isSpeakingOrQueued 转 false、回声窗口过去,这里才会正常收口主人那句。
        guard !isSpeakingOrQueued,
              now.timeIntervalSince(lastSpeechEndedAt) >= echoCooldownSeconds else { return }
        guard isRecording, silenceFinalizeSeconds > 0, !transcript.isEmpty else { return }
        // 收口判据(两条互补,任一满足即收口):
        //  ① 转写稳定:ASR partial 静默超过 silenceFinalizeSeconds(干净环境下快)。
        //  ② 音频静默:主人停止出声(电平降下)超过 audioSilenceFinalizeSeconds——背景噪音持续刷新 partial 让①永不满足时,
        //     靠②兜底收口(嘈杂/连续识别下指令不再永远卡 partial)。
        guard Self.shouldFinalizeUtterance(
            now: now,
            lastPartialAt: lastPartialAt, transcriptStableSeconds: silenceFinalizeSeconds,
            lastLoudInputAt: lastLoudInputAt, audioQuietSeconds: audioSilenceFinalizeSeconds
        ) else { return }
        forceFinalizeUtterance()
    }

    /// 纯函数(可单测):是否该收口当前转写——转写稳定够久 或 主人停止出声够久,任一即收口。
    nonisolated static func shouldFinalizeUtterance(
        now: Date,
        lastPartialAt: Date, transcriptStableSeconds: TimeInterval,
        lastLoudInputAt: Date, audioQuietSeconds: TimeInterval
    ) -> Bool {
        if lastPartialAt != .distantPast, now.timeIntervalSince(lastPartialAt) >= transcriptStableSeconds { return true }
        if lastLoudInputAt != .distantPast, now.timeIntervalSince(lastLoudInputAt) >= audioQuietSeconds { return true }
        return false
    }

    /// 强制把当前 partial 转写当一句 final 提交(走 onResult,isFinal=true → 主线程转入思考),并轮换识别接下一句。
    private func forceFinalizeUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let callbacks = speechCallbacks else { return }
        transcript = ""
        lastPartialAt = .distantPast
        lastLoudInputAt = .distantPast   // 新一句从干净状态重新计音频静默
        lingShuControlLog("voice/asr: 收口「\(text.prefix(24))」→ 转入思考(转写稳定或主人停声)")
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
        cancelPrefetchedSpeech()  // 清演示翻页预合成槽(打断/新回合后那段已不该再播)
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
        micSilenceMonitor?.cancel()
        micSilenceMonitor = nil
        if let obs = configChangeObserver { NotificationCenter.default.removeObserver(obs); configChangeObserver = nil }
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
