@preconcurrency import AVFoundation
import Foundation

// 语音输出拆分在这里，避免 VoiceIOManager 主文件继续膨胀。
@MainActor
extension VoiceIOManager {
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
        let provider = speechOutputProvider
        let endpoint = speechOutputEndpoint
        let apiKey = resolvedSpeechOutputAPIKey(for: provider)
        let persona = speechPersona
        let segments = LingShuSpeechSegmenter.segments(from: cleanedText)

        activeSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if provider.kind == .embeddedSherpaONNXTTS {
                    try await self.speakWithEmbeddedSherpaONNXTTS(cleanedText, provider: provider, persona: persona)
                } else if segments.count > 1 {
                    try await self.speakWithLowLatencySpeechService(
                        segments,
                        provider: provider,
                        endpoint: endpoint,
                        apiKey: apiKey,
                        persona: persona
                    )
                } else {
                    try await self.speakWithSpeechService(
                        cleanedText,
                        provider: provider,
                        endpoint: endpoint,
                        apiKey: apiKey,
                        persona: persona
                    )
                }
            } catch is CancellationError {
                self.isSpeaking = false
                self.setOutputStatus(self.outputStandbyStatus(for: provider))
            } catch {
                self.isSpeaking = false
                self.setOutputStatus("\(provider.displayName) 未响应，已停止发声")
            }
        }
    }

    private func speakWithLowLatencySpeechService(
        _ segments: [String],
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        guard !segments.isEmpty else { return }
        setOutputStatus("正在发声（低延迟）")

        var pending: [Int: Task<Data, Error>] = [:]
        var nextToStart = 0
        let prefetchWindow = min(3, segments.count)

        func enqueue(_ index: Int) {
            let text = segments[index]
            pending[index] = Task.detached(priority: .userInitiated) {
                try await Self.fetchSpeechAudio(
                    text: text,
                    provider: provider,
                    endpoint: endpoint,
                    apiKey: apiKey,
                    persona: persona
                )
            }
        }

        for _ in 0..<prefetchWindow {
            enqueue(nextToStart)
            nextToStart += 1
        }

        defer {
            pending.values.forEach { $0.cancel() }
        }

        for index in segments.indices {
            try Task.checkCancellation()
            guard let task = pending.removeValue(forKey: index) else { continue }
            let audioData = try await task.value
            if nextToStart < segments.count {
                enqueue(nextToStart)
                nextToStart += 1
            }
            try await playSpeechAudioData(audioData, provider: provider, isFinalSegment: index == segments.indices.last)
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
        try await playSpeechAudioData(audioData, provider: provider, isFinalSegment: true)
    }

    private func speakWithSpeechService(
        _ cleanedText: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        let audioData = try await Self.fetchSpeechAudio(
            text: cleanedText,
            provider: provider,
            endpoint: endpoint,
            apiKey: apiKey,
            persona: persona
        )
        try await playSpeechAudioData(audioData, provider: provider, isFinalSegment: true)
    }

    private func playSpeechAudioData(
        _ audioData: Data,
        provider: LingShuSpeechOutputProviderDescriptor,
        isFinalSegment: Bool
    ) async throws {
        let player = try AVAudioPlayer(data: audioData)
        speechAudioPlayer = player
        player.prepareToPlay()
        player.isMeteringEnabled = true
        isSpeaking = true
        player.play()

        let duration = max(player.duration, 0.25)
        try await Task.sleep(nanoseconds: UInt64((duration + 0.08) * 1_000_000_000))
        try Task.checkCancellation()

        if isFinalSegment, player === speechAudioPlayer, speechAudioPlayer?.isPlaying != true {
            isSpeaking = false
            setOutputStatus(outputStandbyStatus(for: provider))
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(estimatedSeconds * 1_000_000_000))
            guard let self, !self.speechSynthesizer.isSpeaking else { return }
            self.isSpeaking = false
            self.setOutputStatus(self.outputStandbyStatus(for: self.speechOutputProvider))
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

        for name in ["Reed", "Eddy", "Rocko", "Grandpa"] {
            if let voice = voices.first(where: { $0.language == "zh-CN" && $0.name == name }) {
                return voice
            }
        }

        return AVSpeechSynthesisVoice(language: "zh-CN")
            ?? voices.first(where: { $0.language.hasPrefix("zh") })
    }

    func outputStandbyStatus(for provider: LingShuSpeechOutputProviderDescriptor) -> String {
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

    private func resolvedSpeechOutputAPIKey(for provider: LingShuSpeechOutputProviderDescriptor) -> String {
        let explicitKey = speechOutputAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard explicitKey.isEmpty, provider.kind == .dataNetSpeakerTTS else {
            return explicitKey
        }
        return bundledRuntimeConfig.token(forProvider: ModelProviderPreset.dataNetGateway.id) ?? ""
    }

    nonisolated static func fetchSpeechAudio(
        text: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws -> Data {
        let request = try LingShuSpeechOutputServiceContract.makeURLRequest(
            endpoint: endpoint,
            provider: provider,
            persona: persona,
            text: text,
            apiKey: apiKey
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LingShuVoiceError.embeddedRuntimeLaunchFailed("TTS 服务 HTTP 状态异常")
        }
        return try decodeSpeechAudioData(data: data, response: httpResponse)
    }

    nonisolated static func decodeSpeechAudioData(data: Data, response: HTTPURLResponse) throws -> Data {
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("application/json") {
            let decoded = try JSONDecoder().decode(LingShuSpeechSynthesisServiceResponse.self, from: data)
            if let audioBase64 = decoded.audioBase64,
               let decodedAudio = Data(base64Encoded: audioBase64) {
                return decodedAudio
            }
            if let audioURLString = decoded.audioURL,
               let audioURL = URL(string: audioURLString) {
                let remoteAudio = try Data(contentsOf: audioURL)
                return remoteAudio
            }
            throw LingShuVoiceError.embeddedRuntimeLaunchFailed("TTS 服务未返回音频")
        }
        return data
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

enum LingShuSpeechSegmenter {
    static func segments(from text: String, maxCharacters: Int = 34, minCharacters: Int = 8) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "。")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else {
            return normalized.isEmpty ? [] : [normalized]
        }

        var result: [String] = []
        var buffer = ""
        let strongBreaks = Set("。！？!?；;")
        let softBreaks = Set("，,、：:")

        func flush() {
            let segment = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                result.append(segment)
            }
            buffer = ""
        }

        for char in normalized {
            buffer.append(char)
            if strongBreaks.contains(char), buffer.count >= minCharacters {
                flush()
            } else if softBreaks.contains(char), buffer.count >= max(minCharacters, maxCharacters / 2) {
                flush()
            } else if buffer.count >= maxCharacters {
                flush()
            }
        }
        flush()

        return result
    }
}
