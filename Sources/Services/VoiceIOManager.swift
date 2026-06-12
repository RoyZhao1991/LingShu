@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

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
    @Published var transcriptionProvider = LingShuVoiceTranscriptionProviderDescriptor.appleSpeech
    @Published private(set) var embeddedASRStatus = LingShuEmbeddedASRRuntimeLocator.senseVoiceSherpaONNXStatus()
    @Published private(set) var embeddedTTSStatus = LingShuEmbeddedTTSRuntimeLocator.sherpaONNXTTSStatus()
    @Published var speechOutputProvider = LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS
    @Published var speechOutputEndpoint = LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS.defaultEndpoint
    @Published var speechOutputAPIKey = ""
    @Published var speechPersona = LingShuSpeechPersona.softDominantMale
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
    private var embeddedASRProcess: Process?
    private var embeddedASROutputHandle: FileHandle?
    private var embeddedASRLineBuffer = ""
    var speechAudioPlayer: AVAudioPlayer?
    var activeSpeechTask: Task<Void, Never>?
    let bundledRuntimeConfig = LingShuBundledRuntimeConfig()

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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let usesOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = usesOnDeviceRecognition
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            throw LingShuVoiceError.audioInputUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: recordingFormat,
            block: makeRecognitionAudioTap(request: request, onAudioChunk: onAudioChunk)
        )

        audioEngine.prepare()
        try audioEngine.start()

        recognitionRequest = request
        isRecording = true
        transcript = ""
        setInputStatus(usesOnDeviceRecognition ? "正在听（本机）" : "正在听")

        recognitionTask = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let recognizedText = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil

            Task { @MainActor in
                guard let self else { return }

                if let recognizedText {
                    let transcription = self.makeTranscriptionResult(text: recognizedText, isFinal: isFinal)
                    self.transcript = transcription.text
                    onText(transcription.text)
                    onResult?(transcription)

                    if isFinal {
                        onFinal?(transcription.text)
                        self.stopRecognition()
                    }
                }

                if hasError {
                    self.stopRecognition()
                    self.setInputStatus("语音识别已中断")
                    if !isFinal {
                        onInterruption?()
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

    /// 立即停止 TTS 播报（用户打断时调用）。
    func stopSpeaking() {
        activeSpeechTask?.cancel()
        speechAudioPlayer?.stop()
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
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
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
