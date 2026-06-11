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
    @Published var speechOutputProvider = LingShuSpeechOutputProviderDescriptor.customHTTPService
    @Published var speechOutputEndpoint = LingShuSpeechOutputProviderDescriptor.customHTTPService.defaultEndpoint
    @Published var speechOutputAPIKey = ""
    @Published var speechPersona = LingShuSpeechPersona.softDominantMale
    /// 实时输入电平 0...1（麦克风 RMS），供极简模式的输入波形使用。
    @Published var inputLevel: Float = 0
    /// 实时输出电平 0...1（TTS 播放音量计），供极简模式的输出波形使用。
    @Published var outputLevel: Float = 0

    var outputMeterTask: Task<Void, Never>?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var embeddedASRProcess: Process?
    private var embeddedASROutputHandle: FileHandle?
    private var embeddedASRLineBuffer = ""
    var speechAudioPlayer: AVAudioPlayer?
    var activeSpeechTask: Task<Void, Never>?
    /// 分句早读队列：流式回复的整句按到达顺序排队播报；
    /// 排队/排空逻辑在 VoiceIOManager+SpeechQueue.swift。
    var speechQueue: [String] = []
    var speechQueueDrainTask: Task<Void, Never>?

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

    /// 立即停止 TTS 播报（用户打断时调用）；同时清空分句早读队列。
    func stopSpeaking() {
        speechQueue.removeAll()
        speechQueueDrainTask?.cancel()
        speechQueueDrainTask = nil
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

    func applySpeechOutputProvider(_ providerID: String) {
        guard let provider = availableSpeechOutputProviders.first(where: { $0.id == providerID }) else { return }
        let previousDefaultEndpoints = Set(availableSpeechOutputProviders.map(\.defaultEndpoint))
        let shouldReplaceEndpoint = speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || previousDefaultEndpoints.contains(speechOutputEndpoint)

        speechOutputProvider = provider
        if shouldReplaceEndpoint {
            speechOutputEndpoint = provider.defaultEndpoint
        }
        setOutputStatus(outputStandbyStatus(for: provider))
    }

    func applySpeechPersona(_ personaID: String) {
        guard let persona = availableSpeechPersonas.first(where: { $0.id == personaID }) else { return }
        speechPersona = persona
        setOutputStatus("\(persona.displayName) 已选定")
    }

    func speak(_ text: String) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }

        activeSpeechTask?.cancel()
        speechAudioPlayer?.stop()
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        if speechOutputProvider.kind == .appleSpeech {
            speakWithAppleSpeech(cleanedText)
            return
        }

        if speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isSpeaking = false
            setOutputStatus("云端 TTS 未配置")
            return
        }

        isSpeaking = true
        setOutputStatus("正在发声（\(speechOutputProvider.displayName)）")
        let provider = speechOutputProvider
        let endpoint = speechOutputEndpoint
        let apiKey = speechOutputAPIKey
        let persona = speechPersona

        activeSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if provider.kind == .embeddedSherpaONNXTTS {
                    try await self.speakWithEmbeddedSherpaONNXTTS(cleanedText, provider: provider, persona: persona)
                } else {
                    try await self.speakWithSpeechService(
                        cleanedText,
                        provider: provider,
                        endpoint: endpoint,
                        apiKey: apiKey,
                        persona: persona
                    )
                }
            } catch {
                self.isSpeaking = false
                self.setOutputStatus("\(provider.displayName) 未响应，已停止发声")
            }
        }
    }

    private func speakWithEmbeddedSherpaONNXTTS(
        _ cleanedText: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        persona: LingShuSpeechPersona
    ) async throws {
        refreshEmbeddedTTSRuntimeStatus()
        let status = embeddedTTSStatus
        guard status.isAvailable,
              let runtimePath = status.runtimePath else {
            throw LingShuVoiceError.embeddedRuntimeUnavailable(status.diagnosticSummary)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-tts-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("wav")
        let arguments = try LingShuEmbeddedTTSRuntimeLocator.processArguments(
            status: status,
            text: cleanedText,
            persona: persona,
            outputURL: outputURL
        )
        try await Self.runEmbeddedTTSProcess(
            runtimePath: runtimePath,
            arguments: arguments,
            outputURL: outputURL
        )

        let audioData = try Self.readGeneratedAudioAndRemoveFile(at: outputURL)
        let player = try AVAudioPlayer(data: audioData)
        speechAudioPlayer = player
        player.prepareToPlay()
        player.isMeteringEnabled = true
        isSpeaking = true
        setOutputStatus("正在发声（\(provider.displayName)）")
        player.play()

        let duration = max(player.duration, 1.0)
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.25) * 1_000_000_000))
            guard let self else { return }
            if player === self.speechAudioPlayer, self.speechAudioPlayer?.isPlaying != true {
                self.isSpeaking = false
                self.setOutputStatus(self.outputStandbyStatus(for: provider))
            }
        }
    }

    private func speakWithSpeechService(
        _ cleanedText: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        let request = try LingShuSpeechOutputServiceContract.makeURLRequest(
            endpoint: endpoint,
            provider: provider,
            persona: persona,
            text: cleanedText,
            apiKey: apiKey
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LingShuVoiceError.embeddedRuntimeLaunchFailed("TTS 服务 HTTP 状态异常")
        }

        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let audioData: Data
        if contentType.contains("application/json") {
            let decoded = try JSONDecoder().decode(LingShuSpeechSynthesisServiceResponse.self, from: data)
            if let audioBase64 = decoded.audioBase64,
               let decodedAudio = Data(base64Encoded: audioBase64) {
                audioData = decodedAudio
            } else if let audioURLString = decoded.audioURL,
                      let audioURL = URL(string: audioURLString) {
                let (remoteAudio, _) = try await URLSession.shared.data(from: audioURL)
                audioData = remoteAudio
            } else {
                throw LingShuVoiceError.embeddedRuntimeLaunchFailed("TTS 服务未返回音频")
            }
        } else {
            audioData = data
        }

        let player = try AVAudioPlayer(data: audioData)
        speechAudioPlayer = player
        player.prepareToPlay()
        player.isMeteringEnabled = true
        isSpeaking = true
        setOutputStatus("正在发声（\(provider.displayName)）")
        player.play()

        let duration = max(player.duration, 1.0)
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.25) * 1_000_000_000))
            guard let self else { return }
            if player === self.speechAudioPlayer, self.speechAudioPlayer?.isPlaying != true {
                self.isSpeaking = false
                self.setOutputStatus("\(provider.displayName) 待机")
            }
        }
    }

    private func speakWithAppleSpeech(_ cleanedText: String, statusAlreadySet: Bool = false) {
        let utterance = AVSpeechUtterance(string: cleanedText)
        utterance.voice = preferredChineseVoice()
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.94
        utterance.volume = 1.0

        isSpeaking = true
        if !statusAlreadySet {
            setOutputStatus("正在发声（macOS 中文男声）")
        }
        speechSynthesizer.speak(utterance)

        let estimatedSeconds = min(max(Double(cleanedText.count) * 0.16, 1.2), 28.0)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(estimatedSeconds * 1_000_000_000))
            if !speechSynthesizer.isSpeaking {
                isSpeaking = false
                setOutputStatus(self.outputStandbyStatus(for: self.speechOutputProvider))
            }
        }
    }

    func markInputError(_ message: String) {
        setInputStatus(message)
    }

    private func setInputStatus(_ message: String) {
        inputStatusMessage = message
        refreshOverallStatus()
    }

    private func setOutputStatus(_ message: String) {
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

    private func preferredChineseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()

        let preferredIdentifiers = [
            "com.apple.eloquence.zh-CN.Reed",
            "com.apple.eloquence.zh-CN.Eddy",
            "com.apple.eloquence.zh-CN.Rocko",
            "com.apple.eloquence.zh-CN.Grandpa"
        ]

        for identifier in preferredIdentifiers {
            if let voice = voices.first(where: { $0.identifier == identifier }) {
                return voice
            }
        }

        let preferredNames = ["Reed", "Eddy", "Rocko", "Grandpa"]
        for name in preferredNames {
            if let voice = voices.first(where: { $0.language == "zh-CN" && $0.name == name }) {
                return voice
            }
        }

        return AVSpeechSynthesisVoice(language: "zh-CN")
            ?? voices.first(where: { $0.language.hasPrefix("zh") })
    }

    private func outputStandbyStatus(for provider: LingShuSpeechOutputProviderDescriptor) -> String {
        switch provider.kind {
        case .appleSpeech:
            return "中文男声待机"
        case .embeddedSherpaONNXTTS:
            return embeddedTTSStatus.isAvailable ? "本地 VITS 待机" : "本地 VITS 未就绪"
        case .customHTTPService where speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return "云端 TTS 待配置"
        default:
            return "\(provider.displayName) 待机"
        }
    }

    private nonisolated static func runEmbeddedTTSProcess(
        runtimePath: String,
        arguments: [String],
        outputURL: URL
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtimePath)
            process.currentDirectoryURL = URL(fileURLWithPath: runtimePath).deletingLastPathComponent()
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            let libraryPath = LingShuEmbeddedTTSRuntimeLocator.dynamicLibraryPath(for: runtimePath)
            let existingLibraryPath = environment["DYLD_LIBRARY_PATH"] ?? ""
            environment["DYLD_LIBRARY_PATH"] = existingLibraryPath.isEmpty
                ? libraryPath
                : "\(libraryPath):\(existingLibraryPath)"
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            final class ProcessBox: @unchecked Sendable {
                var didResume = false
            }
            let box = ProcessBox()

            process.terminationHandler = { completedProcess in
                guard !box.didResume else { return }
                box.didResume = true

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let diagnostic = String(data: errorData + outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if completedProcess.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: outputURL.path) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LingShuVoiceError.embeddedRuntimeLaunchFailed(
                        diagnostic.isEmpty ? "sherpa-onnx-offline-tts 退出码 \(completedProcess.terminationStatus)" : diagnostic
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                guard !box.didResume else { return }
                box.didResume = true
                continuation.resume(throwing: LingShuVoiceError.embeddedRuntimeLaunchFailed(error.localizedDescription))
            }
        }
    }

    nonisolated static func readGeneratedAudioAndRemoveFile(at outputURL: URL) throws -> Data {
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        return try Data(contentsOf: outputURL)
    }

}
