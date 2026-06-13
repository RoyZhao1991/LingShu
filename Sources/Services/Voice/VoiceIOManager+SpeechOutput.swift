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

        // 网关男声需要 token；读不到就别发空请求——直接说明原因并降级，让"为什么是本机生硬音"一眼可诊断。
        if provider.kind == .dataNetSpeakerTTS,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setOutputStatus("云端男声缺凭据（钥匙串未读到 datanet token），已降级本机语音")
            speakWithAppleSpeech(cleanedText, statusAlreadySet: true)
            return
        }

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
                // 云端男声请求失败（网关异常/鉴权失败）：显示原因并降级本机语音兜底。
                self.setOutputStatus("云端男声请求失败（\(String(describing: error).prefix(50))），已降级本机语音")
                self.speakWithAppleSpeech(cleanedText, statusAlreadySet: true)
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
        let voice = preferredChineseVoice()
        utterance.voice = voice
        utterance.rate = 0.45
        // 有真男声（如用户下载的 Li-mu）用自然音高；本机只剩女声兜底时大幅压低音高近似男声。
        utterance.pitchMultiplier = (voice?.gender == .male) ? 0.92 : 0.68
        utterance.volume = 1.0

        isSpeaking = true
        if !statusAlreadySet {
            setOutputStatus("正在发声（本机系统语音·兜底）")
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

    /// 选一个中文**男声**（贾维斯式沉稳男声为目标）。
    /// macOS 自带 Eloquence 中文嗓不上报 gender（全 unspecified），系统默认 zh-CN 是女声（婷婷）——
    /// 这正是之前"灵枢说话是女声"的根因：旧逻辑虽优先 Eloquence 但首选嗓偏中性，听感像女声。
    /// 这里：先取 API 明确标记的男声（用户若下载了 Li-mu 等高质量神经男声会优先命中），
    /// 否则按名单锁定 Eloquence 男声并排除已知女声；实在没有才退回默认。
    /// 选一个**能发声的**中文男声（贾维斯式沉稳男声为目标）。
    /// 关键坑：macOS 自带 Eloquence 中文嗓（Eddy/Reed/Rocko/Grandpa…）在本机实测**渲染为静音**
    /// （0.016s 空音频）——之前选了它就"没声音"。所以一律跳过 Eloquence，避免哑嗓。
    /// 真男声（用户下载的 Li-mu 等高质量神经男声，gender==.male）优先；本机若只剩女声，
    /// 退回最佳可发声中文嗓，由 speakWithAppleSpeech 压低音高近似男声。
    private func preferredChineseVoice() -> AVSpeechSynthesisVoice? {
        let zh = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        let audible = zh.filter { !$0.identifier.contains(".eloquence.") }
        let pool = audible.isEmpty ? zh : audible

        // 优先真正的男声（用户在系统设置下载 zh-CN 男声后命中，自然男声）。
        if let male = pool.filter({ $0.gender == .male })
            .sorted(by: { $0.quality.rawValue > $1.quality.rawValue })
            .first {
            return male
        }

        // 本机没有可发声的中文男声：退回最佳可发声中文嗓（优先 zh-CN、再优先高音质）。
        return pool.sorted { lhs, rhs in
            if (lhs.language == "zh-CN") != (rhs.language == "zh-CN") { return lhs.language == "zh-CN" }
            return lhs.quality.rawValue > rhs.quality.rawValue
        }.first ?? AVSpeechSynthesisVoice(language: "zh-CN")
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
        // 网关情绪男声的凭据：先包内 RuntimeConfig（随包交付），再退回钥匙串（用户已存的 datanet token）。
        // 之前只读 RuntimeConfig，本机没放 token 文件 → 拿不到凭据 → 云端男声请求失败，这就是"还是女声/没声音"的根因。
        let providerID = ModelProviderPreset.dataNetGateway.id
        if let bundled = bundledRuntimeConfig.token(forProvider: providerID),
           !bundled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundled
        }
        return credentialStore.apiKey(forProvider: providerID) ?? ""
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
