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
    /// **保留换行**(用 \n 连接清洗后的各行)——朗读分段一律按换行切(见 LingShuSpeechSegmenter),
    /// 所以这里不能把行拼成一长串(否则就只剩一段、丢了分段)。空行/代码/表格已在此剔除,不会产生空段。
    static func strippedForSpeech(_ text: String) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || t.hasPrefix("|") { continue }   // 代码块、表格行不念
            if t.hasPrefix("⏱") { continue }             // "总用时" 后缀不念(纯展示用,念出来很怪)
            if t.isEmpty { continue }
            var line = t.replacingOccurrences(of: "^[#>\\-*+\\s]+", with: "", options: .regularExpression)
            for marker in ["**", "`", "#"] { line = line.replacingOccurrences(of: marker, with: "") }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        let joined = lines.joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String) {
        // 朗读前剥 markdown(代码块/表格/标记):否则长回复会把 `**`、`|`、`-` 等当文本念,既乱又可能整段失败。
        let cleanedText = Self.strippedForSpeech(text)
        guard !cleanedText.isEmpty else { return }

        // 递增发声代次:本次之后再有新发声/降级都会让先前在飞的音频「过期」(下方各处按 gen 守卫,不再出声/不翻转状态)。
        speechGeneration &+= 1
        let gen = speechGeneration

        activeSpeechTask?.cancel()
        speechAudioPlayer?.stop()
        activeStreamingPlayer?.stop()
        activeStreamingPlayer = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        // 本机嗓,或国际化选了**英文**(云端 CosyVoice2 是中文男声,英文走本机英文嗓)→ 本机 TTS。
        if speechOutputProvider.kind == .appleSpeech || voiceLanguage == .english {
            speakWithAppleSpeech(cleanedText, generation: gen)
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
            speakWithAppleSpeech(cleanedText, statusAlreadySet: true, generation: gen)
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
                        persona: persona,
                        generation: gen
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
                // 被更新的发声取代才会取消:本任务已过期则不翻转状态(否则会把新发声的 isSpeaking 误清成 false)。
                guard self.speechGeneration == gen else { return }
                self.isSpeaking = false
                self.setOutputStatus(self.outputStandbyStatus(for: provider))
            } catch {
                // 云端男声请求失败（网关异常/超时/鉴权失败）：降级本机语音兜底。
                // 先确认本任务仍是当前代次——已被更新发声接管就直接放弃,**绝不在新发声上再叠一层本机降级音**(双声线根因)。
                guard self.speechGeneration == gen else { return }
                // 再停掉可能还在放的云端流式播放器,然后才起降级本机语音。
                self.activeStreamingPlayer?.stop()
                self.activeStreamingPlayer = nil
                self.speechAudioPlayer?.stop()
                let reason = "云端男声请求失败（\(Self.shortFailureReason(error))），已降级本机语音"
                lingShuControlLog("TTS speak() 降级本机: \(Self.shortFailureReason(error)) | 文本\(cleanedText.count)字 段数=\(LingShuSpeechSegmenter.segments(from: cleanedText).count) 「\(cleanedText.prefix(20))」")
                self.cloudVoiceDegradedReason = reason
                self.setOutputStatus(reason)
                self.speakWithAppleSpeech(cleanedText, statusAlreadySet: true, generation: gen)
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
        persona: LingShuSpeechPersona,
        generation: Int
    ) async throws {
        let parts = segments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { return }
        isSpeaking = true
        setOutputStatus("正在发声（流式）")
        defer {
            // 仅当仍是当前代次才收口:被更新发声取消时别把新发声的 isSpeaking 误清成 false。
            if speechGeneration == generation {
                isSpeaking = false
                setOutputStatus(outputStandbyStatus(for: provider))
            }
        }
        // 单段:真流式,首包即播(最低延迟)。多段:连续播放器 + 管线预取,段间背靠背不排空到静音——
        // 根治"带格式/长回复分成很多小段、每段都等下一段首包"的卡顿。
        if parts.count == 1 {
            try await streamSpeechSegment(parts[0], provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
        } else {
            try await speakSegmentsContinuously(parts, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
        }
    }

    /// 多段连续:用**一个**流式 PCM 播放器贯穿全程。每段并行预取整段 WAV、按序把 PCM 背靠背排进同一播放器
    /// (段间不排空到静音=无缝)。**关键:整段 WAV 拉取 + WAV 解析 + 建 buffer + enqueue 全在后台线程**
    /// (`renderStreamingSegment`/`Task.detached`),主线程只协调——否则主线程一忙(在岗感知)就喂不上 → 卡顿。
    /// (旧实现首段用 `URLSession.bytes` 逐字节在主线程边收边喂 = 在岗音频卡顿真凶,已弃。)
    private func speakSegmentsContinuously(
        _ parts: [String],
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        var pending: [Int: Task<Data, Error>] = [:]
        // 预取窗口够深:每段一次完整合成往返、段又短,窗口浅会被播放追上→段间饿出间隔。8 路并行让合成跑在播放前面。
        let window = min(8, parts.count)
        var nextToPrefetch = 0

        func prefetch(_ index: Int) {
            guard index < parts.count, pending[index] == nil else { return }
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
        topUpPrefetch()

        var player: LingShuStreamingPCMPlayer?
        var firstRate: Double = 0
        let levelSink: @Sendable (Float) -> Void = { [weak self] level in Task { @MainActor in self?.outputLevel = level } }
        defer {
            pending.values.forEach { $0.cancel() }
            if Task.isCancelled { player?.stop(); activeStreamingPlayer = nil }
        }

        for index in 0..<parts.count {
            try Task.checkCancellation()
            if pending[index] == nil { prefetch(index) }
            guard let task = pending.removeValue(forKey: index) else { continue }
            // 单段失败只**跳过**,不抛错(否则冒到外层触发本机兜底 → 与云端播放器叠加=双声线)。用户取消才停并上抛。
            let wav: Data
            do {
                wav = try await task.value
            } catch is CancellationError {
                player?.stop(); activeStreamingPlayer = nil
                throw CancellationError()
            } catch {
                topUpPrefetch()
                continue
            }
            topUpPrefetch()
            try Task.checkCancellation()
            // 重活(WAV 解析 + 建 buffer + enqueue)全程后台线程,主线程不参与。
            let existing = player
            let rate = firstRate
            let outcome = await Task.detached(priority: .userInitiated) {
                VoiceIOManager.renderStreamingSegment(wav: wav, firstSampleRate: rate, existingPlayer: existing, onOutputLevel: levelSink)
            }.value
            if firstRate == 0, outcome.sampleRate > 0 { firstRate = outcome.sampleRate }
            if let created = outcome.player, player == nil {
                player = created
                activeStreamingPlayer = created
                cloudVoiceDegradedReason = nil
            }
        }

        if let player {
            await player.finishAndDrain()
        }
        activeStreamingPlayer = nil
    }

    /// 单段:整段 WAV 后台拉取 + 后台渲染喂进播放器,播完排空。**不在主线程逐字节/喂 PCM**(在岗不卡)。
    private func streamSpeechSegment(
        _ text: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws {
        let wav = try await Task.detached(priority: .userInitiated) {
            try await Self.fetchSpeechAudio(text: text, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
        }.value
        try Task.checkCancellation()
        let levelSink: @Sendable (Float) -> Void = { [weak self] level in Task { @MainActor in self?.outputLevel = level } }
        let outcome = await Task.detached(priority: .userInitiated) {
            VoiceIOManager.renderStreamingSegment(wav: wav, firstSampleRate: 0, existingPlayer: nil, onOutputLevel: levelSink)
        }.value
        guard let player = outcome.player else {
            throw LingShuVoiceError.embeddedRuntimeLaunchFailed("流式 TTS 未返回有效音频")
        }
        activeStreamingPlayer = player
        cloudVoiceDegradedReason = nil
        await player.finishAndDrain()
        activeStreamingPlayer = nil
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

    private func speakWithAppleSpeech(_ cleanedText: String, statusAlreadySet: Bool = false, generation: Int) {
        // 过期发声(已被更新发声/取消取代)不再发出本机音——防止与新发声或云端 TTS 重叠(双声线)。
        guard generation == speechGeneration else { return }
        let utterance = AVSpeechUtterance(string: cleanedText)
        // 国际化:英文走本机英文嗓(自然音高);中文走男声逻辑(压低近似男声)。
        let isEnglish = voiceLanguage == .english
        let voice = isEnglish ? preferredEnglishVoice() : preferredChineseVoice()
        utterance.voice = voice
        utterance.rate = 0.45
        // 有真男声（如用户下载的 Li-mu）用自然音高；本机只剩女声兜底时大幅压低音高近似男声;英文用自然音高。
        utterance.pitchMultiplier = isEnglish ? 1.0 : ((voice?.gender == .male) ? 0.92 : 0.68)
        utterance.volume = 1.0

        isSpeaking = true
        if !statusAlreadySet {
            setOutputStatus("正在发声（本机系统语音·兜底）")
        }
        speechSynthesizer.speak(utterance)

        let estimatedSeconds = min(max(Double(cleanedText.count) * 0.16, 1.2), 28.0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(estimatedSeconds * 1_000_000_000))
            // 仅当仍是当前代次、且系统语音确已停,才收口——否则别误把更新发声的 isSpeaking 清成 false。
            guard let self, self.speechGeneration == generation, !self.speechSynthesizer.isSpeaking else { return }
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

    /// 选一个**英文**嗓(优先 en-US 高音质,男声优先)。国际化语音选 English 时用。
    private func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let pool = en.filter { !$0.identifier.contains(".eloquence.") }
        let candidates = pool.isEmpty ? en : pool
        if let male = candidates.filter({ $0.gender == .male })
            .sorted(by: { $0.quality.rawValue > $1.quality.rawValue }).first { return male }
        return candidates.sorted { lhs, rhs in
            if (lhs.language == "en-US") != (rhs.language == "en-US") { return lhs.language == "en-US" }
            return lhs.quality.rawValue > rhs.quality.rawValue
        }.first ?? AVSpeechSynthesisVoice(language: "en-US")
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

    func resolvedSpeechOutputAPIKey(for provider: LingShuSpeechOutputProviderDescriptor) -> String {
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
    /// 超长行兜底阈值:一行超过这么多字,就按句末标点二次切。
    /// 云端 `/stream` 对长段又慢又只合成首句——短行保持整段(自然),长行才拆,避免超时/漏读后半。
    static let maxSegmentChars = 36

    /// **主切分=换行**(一行=一段,短行不拆,听感自然);**超长行按句末标点二次切**(兜住云端长段限制)。
    /// `strippedForSpeech` 已保留换行;空行已剔除,不产生空段。
    static func segments(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { $0.count <= maxSegmentChars ? [$0] : splitLongLine($0) }
    }

    /// 长行二次切:先按句末标点(。！？!?…；;)切;若某片仍极长(无标点的长句),再按字数硬切兜底。
    private static func splitLongLine(_ line: String) -> [String] {
        let enders = Set("。！？!?…；;")
        var pieces: [String] = []
        var buffer = ""
        for char in line {
            buffer.append(char)
            if enders.contains(char) {
                let piece = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { pieces.append(piece) }
                buffer = ""
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        // 仍有超长片(无句末标点的长句)→ 按字数硬切,保证每段都在云端可承受范围。
        return pieces.flatMap { piece -> [String] in
            guard piece.count > maxSegmentChars * 2 else { return [piece] }
            var chunks: [String] = []
            var idx = piece.startIndex
            while idx < piece.endIndex {
                let end = piece.index(idx, offsetBy: maxSegmentChars, limitedBy: piece.endIndex) ?? piece.endIndex
                chunks.append(String(piece[idx..<end]))
                idx = end
            }
            return chunks
        }
    }
}
