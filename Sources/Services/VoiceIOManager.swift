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
            }
        }
    }
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

    var outputMeterTask: Task<Void, Never>?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
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
        isRecording = true
        transcript = ""
        setInputStatus(speechRecognizer.supportsOnDeviceRecognition ? "正在听（本机）" : "正在听")
        armSpeechRecognition()
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
                    let transcription = self.makeTranscriptionResult(text: recognizedText, isFinal: isFinal)
                    self.transcript = transcription.text
                    callbacks.onText(transcription.text)
                    callbacks.onResult?(transcription)

                    if isFinal {
                        callbacks.onFinal?(transcription.text)
                        self.armSpeechRecognition()   // 无缝轮换到下一句
                    }
                }

                if hasError {
                    self.stopRecognition()
                    self.setInputStatus("语音识别已中断")
                    if !isFinal {
                        callbacks.onInterruption?()
                    }
                }
            }
        }
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
