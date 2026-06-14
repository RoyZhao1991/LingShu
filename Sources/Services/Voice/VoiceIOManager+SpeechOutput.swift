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

    /// 朗读用文本清洗:去掉代码块、表格行、markdown 标记,只留可念的正文。
    static func strippedForSpeech(_ text: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || t.hasPrefix("|") { continue }   // 代码块、表格行不念
            if t.isEmpty { continue }
            var line = t.replacingOccurrences(of: "^[#>\\-*+\\s]+", with: "", options: .regularExpression)
            for marker in ["**", "`", "#"] { line = line.replacingOccurrences(of: marker, with: "") }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        let joined = lines.joined(separator: "。 ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String) {
        // 朗读前剥 markdown(代码块/表格/标记):否则长回复会把 `**`、`|`、`-` 等当文本念,既乱又可能整段失败。
        let cleanedText = Self.strippedForSpeech(text)
        guard !cleanedText.isEmpty else { return }

        activeSpeechTask?.cancel()
        speechAudioPlayer?.stop()
        activeStreamingPlayer?.stop()
        activeStreamingPlayer = nil
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
            let reason = "云端男声缺凭据（未读到 datanet token），已降级本机语音"
            cloudVoiceDegradedReason = reason
            setOutputStatus(reason)
            speakWithAppleSpeech(cleanedText, statusAlreadySet: true)
            return
        }

        let segments = LingShuSpeechSegmenter.segments(from: cleanedText)

        activeSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if provider.kind == .embeddedSherpaONNXTTS {
                    try await self.speakWithEmbeddedSherpaONNXTTS(cleanedText, provider: provider, persona: persona)
                } else if provider.supportsStreaming {
                    // 流式 provider(如 dataNet):统一走流式 PCM 播放器,按段循环——
                    // 首段首包即播(低延迟),多段顺序播(避开服务端长文本只合成第一句 + AVAudioPlayer 占位WAV 卡死)。
                    try await self.speakWithStreamingSegments(
                        segments.isEmpty ? [cleanedText] : segments,
                        provider: provider,
                        endpoint: endpoint,
                        apiKey: apiKey,
                        persona: persona
                    )
                } else if segments.count > 1 {
                    // 非流式 provider:逐段拉全量音频(AVAudioPlayer)再顺序播。
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
                // 云端男声请求失败（网关异常/超时/鉴权失败）：降级本机语音兜底。
                // **先停掉可能还在放的云端流式播放器**——否则本机声线会和云端声线叠在一起(双声线)。
                self.activeStreamingPlayer?.stop()
                self.activeStreamingPlayer = nil
                self.speechAudioPlayer?.stop()
                let reason = "云端男声请求失败（\(Self.shortFailureReason(error))），已降级本机语音"
                self.cloudVoiceDegradedReason = reason
                self.setOutputStatus(reason)
                self.speakWithAppleSpeech(cleanedText, statusAlreadySet: true)
            }
        }
    }

    /// 真流式发声：POST 到 /stream，用 URLSession.bytes 边收边喂给 PCM 播放器——首块即出声、中途可打断。
    /// 多段顺序流式:服务端 /stream 对长文本只合成第一句就停,故按句**逐段**流式播放、首段首包即播。
    /// 全程统一管 isSpeaking(段间不翻转,避免语音通话误判"回应结束"而提前重新听)。
    private func speakWithStreamingSegments(
        _ segments: [String],
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        let parts = segments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { return }
        isSpeaking = true
        setOutputStatus("正在发声（流式）")
        defer {
            isSpeaking = false
            setOutputStatus(outputStandbyStatus(for: provider))
        }
        // 单段:真流式,首包即播(最低延迟)。多段:连续播放器 + 管线预取,段间背靠背不排空到静音——
        // 根治"带格式/长回复分成很多小段、每段都等下一段首包"的卡顿。
        if parts.count == 1 {
            try await streamSpeechSegment(parts[0], provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
        } else {
            try await speakSegmentsContinuously(parts, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
        }
    }

    /// 多段连续流式:用**一个**流式 PCM 播放器贯穿全程。
    /// **首段真流式**(边收边喂,首包即出声 → 首声最快),其余段并行预取整段 WAV、按序把 PCM 背靠背
    /// 排进同一播放器——段间不再排空到静音、不再每段重等首包,从而首声快又全程不卡。
    private func speakSegmentsContinuously(
        _ parts: [String],
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        var pending: [Int: Task<Data, Error>] = [:]
        let window = min(3, parts.count)
        var nextToPrefetch = 1   // 第 0 段真流式,不预取;从第 1 段起并行预取整段音频

        func prefetch(_ index: Int) {
            guard index >= 1, index < parts.count, pending[index] == nil else { return }
            let text = parts[index]
            pending[index] = Task.detached(priority: .userInitiated) {
                try await Self.fetchSpeechAudio(text: text, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
            }
        }
        func topUpPrefetch() {
            while nextToPrefetch < parts.count, pending.count < window {
                prefetch(nextToPrefetch)
                nextToPrefetch += 1
            }
        }
        topUpPrefetch()   // 首段流式期间,第 1..window 段已在并行下载
        defer {
            pending.values.forEach { $0.cancel() }
            if Task.isCancelled { activeStreamingPlayer?.stop(); activeStreamingPlayer = nil }
        }

        // 首段:真流式喂进共享播放器(首包即播),返回仍在播的播放器——后续段继续往里灌,不排空。
        let player = try await openStreamingSegment(parts[0], provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)

        // 其余段:用预取好的整段 WAV,剥头取 PCM 背靠背喂进同一播放器(连续无缝)。
        for index in 1..<parts.count {
            try Task.checkCancellation()
            if pending[index] == nil { prefetch(index) }
            guard let task = pending.removeValue(forKey: index) else { continue }
            // 单段失败只**跳过**,不抛错——一旦抛错会冒到外层触发本机语音兜底,而云端播放器还在放 → 双声线。
            // (首段已成功=云端可用;后面偶发的某段失败不该让整轮回落。)用户主动取消才停止并上抛。
            let wav: Data
            do {
                wav = try await task.value
            } catch is CancellationError {
                player.stop(); activeStreamingPlayer = nil
                throw CancellationError()
            } catch {
                topUpPrefetch()
                continue
            }
            topUpPrefetch()
            try Task.checkCancellation()
            let bytes = [UInt8](wav)
            guard let located = LingShuStreamingWAVHeader.locate(in: bytes), located.pcmStart < bytes.count else { continue }
            player.enqueue(pcm16: Data(bytes[located.pcmStart...]))
        }

        await player.finishAndDrain()
        activeStreamingPlayer = nil
    }

    /// 单段流式:首包即播,播完排空。复用 openStreamingSegment(共享同一段流式实现)。
    private func streamSpeechSegment(
        _ text: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        let player = try await openStreamingSegment(text, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
        await player.finishAndDrain()
        activeStreamingPlayer = nil
    }

    /// 打开一段真流式:POST /stream,用 URLSession.bytes 边收边喂(按字节,**不依赖 WAV 占位长度头**,
    /// 避开 AVAudioPlayer 对占位长度读出错误时长导致的卡死),返回**仍在播放**的播放器(不 drain)——
    /// 供单段朗读或连续多段的首段复用。不动 isSpeaking,交外层统一管。
    private func openStreamingSegment(
        _ text: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws -> LingShuStreamingPCMPlayer {
        let request = try LingShuSpeechOutputServiceContract.makeURLRequest(
            endpoint: endpoint,
            provider: provider,
            persona: persona,
            text: text,
            apiKey: apiKey
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LingShuVoiceError.embeddedRuntimeLaunchFailed("流式 TTS HTTP 状态异常")
        }

        var headerBytes: [UInt8] = []
        var pcmBatch = Data()
        var player: LingShuStreamingPCMPlayer?
        let flushThreshold = 3200   // ≈100ms：小到低延迟、又不至于碎成太多 buffer。

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if player == nil {
                    headerBytes.append(byte)
                    guard let located = LingShuStreamingWAVHeader.locate(in: headerBytes) else { continue }
                    guard let started = LingShuStreamingPCMPlayer(sampleRate: located.sampleRate) else {
                        throw LingShuVoiceError.embeddedRuntimeLaunchFailed("流式播放器初始化失败")
                    }
                    try started.start()
                    player = started
                    activeStreamingPlayer = started
                    cloudVoiceDegradedReason = nil   // 流式拿到音频，清掉之前的降级标记。
                    if located.pcmStart < headerBytes.count {
                        started.enqueue(pcm16: Data(headerBytes[located.pcmStart...]))
                    }
                } else {
                    pcmBatch.append(byte)
                    if pcmBatch.count >= flushThreshold {
                        player?.enqueue(pcm16: pcmBatch)
                        pcmBatch.removeAll(keepingCapacity: true)
                    }
                }
            }
        } catch is CancellationError {
            player?.stop()
            activeStreamingPlayer = nil
            throw CancellationError()
        }

        guard let player else {
            throw LingShuVoiceError.embeddedRuntimeLaunchFailed("流式 TTS 未返回有效音频")
        }
        if !pcmBatch.isEmpty { player.enqueue(pcm16: pcmBatch) }
        return player
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
        // 云端男声这次合成+播放成功 → 清掉降级告警（底部告警条随之消失）。
        if provider.kind == .dataNetSpeakerTTS {
            cloudVoiceDegradedReason = nil
        }
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

    /// 把底层错误压成一句人话，优先把"超时"点名出来（这是云端 TTS 最常见的降级原因）。
    nonisolated static func shortFailureReason(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时"
            case .notConnectedToInternet, .networkConnectionLost: return "网络中断"
            case .cannotConnectToHost, .cannotFindHost: return "网关连不上"
            default: return "网络错误 \(urlError.code.rawValue)"
            }
        }
        return String(describing: error).prefix(40).description
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
    /// **仅按句末标点(。！？及半角 !? …)与换行**切分朗读段——干净的整句分段。
    /// 不再按逗号/冒号/字数硬切(那会把一句话碎成怪异短段、还让段间多出停顿)。
    /// 单句很长也不强切:它本就是一句,云端按整句合成不会被截断。
    static func segments(from text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        let sentenceEnders = Set("。！？!?…")

        func flush() {
            let segment = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { result.append(segment) }
            buffer = ""
        }

        for char in text {
            if char == "\n" || char == "\r" {   // 换行即分段
                flush()
                continue
            }
            buffer.append(char)
            if sentenceEnders.contains(char) { flush() }   // 句末标点即分段
        }
        flush()
        return result
    }
}
