import Foundation

/// 增量无缝流式发声:模型逐句吐字时,每出现一句(。/换行)就喂进来——本模块按**有界窗口并行预取**各句 TTS WAV,
/// 再**按句序背靠背**把 PCM 灌进**同一个持续播放器**,无缝顺序播放。
///
/// 稳健性要点(2026-06-16 修噪音/卡顿):
///  - 每段**独立偶数对齐**后再 enqueue(16-bit 样本):杜绝某段奇数字节经播放器 leftover 串到下一段 → 错位半样本 → 之后全噪音;
///  - **采样率一致性校验**:后续段采样率与首段不符则跳过(否则按首段固定 format 播会音高错/噪音);
///  - **有界预取窗口**:不一上来并发几十个 TTS 请求打爆服务端(那会让某段又慢又返回畸形 → 卡顿 + 噪音);
///  - 单段失败/畸形只**跳过**(绝不抛错触发本机降级叠加 = 双声线)。
///
/// 仅对**云端流式 provider**(dataNet 等,有凭据)启用;本机/无凭据退回逐句 speakQueued。
@MainActor
extension VoiceIOManager {

    /// 并发预取窗口:同时在合成的句子数上限。TTS 较重——攒 3 路把合成跑在播放前面,又不压垮服务端。
    private var streamingSpeechPrefetchWindow: Int { 3 }

    /// 喂一句进增量流式发声。首句会开一个新会话(占发声代次、停掉之前在飞的发声,防双声线)。
    func speakStreamingSentence(_ text: String) {
        let cleaned = Self.strippedForSpeech(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let provider = speechOutputProvider
        let apiKey = resolvedSpeechOutputAPIKey(for: provider)
        let endpoint = speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloudStreaming = provider.supportsStreaming
            && provider.kind != .appleSpeech
            && !endpoint.isEmpty
            && !(provider.kind == .dataNetSpeakerTTS && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard cloudStreaming else {
            lingShuControlLog("TTS 退回逐句 speakQueued: provider=\(provider.displayName) streamCap=\(provider.supportsStreaming) endpointEmpty=\(endpoint.isEmpty) keyEmpty=\(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
            speakQueued(cleaned)
            return
        }

        if streamingSpeechDrainTask == nil {
            lingShuControlLog("TTS 无缝流式发声开始 provider=\(provider.displayName)")
            beginStreamingSpeechSession(provider: provider, endpoint: endpoint, apiKey: apiKey, persona: speechPersona)
        }
        let index = streamingSpeechNextIndex
        streamingSpeechNextIndex += 1
        streamingSpeechTexts[index] = cleaned   // 只登记文本,由 drainer 按窗口预取(不一上来全发)
    }

    /// 标记本次流式发声没有更多句子:drainer 把剩余句子播完后收口(finishAndDrain)。
    func finishStreamingSpeech() {
        guard streamingSpeechDrainTask != nil else { return }
        streamingSpeechEnded = true
    }

    /// 取消流式发声(用户打断 / 新回合):停播放器、取消预取、复位。
    func cancelStreamingSpeech() {
        streamingSpeechDrainTask?.cancel()
        streamingSpeechDrainTask = nil
        streamingSpeechPrefetch.values.forEach { $0.cancel() }
        streamingSpeechPrefetch.removeAll()
        streamingSpeechTexts.removeAll()
        streamingSpeechPlayer?.stop()
        streamingSpeechPlayer = nil
        streamingSpeechNextIndex = 0
        streamingSpeechNextToPlay = 0
        streamingSpeechFirstSampleRate = 0
        streamingSpeechEnded = false
        streamingSpeechConfig = nil
    }

    private func beginStreamingSpeechSession(provider: LingShuSpeechOutputProviderDescriptor, endpoint: String, apiKey: String, persona: LingShuSpeechPersona) {
        speechGeneration &+= 1
        let gen = speechGeneration
        activeSpeechTask?.cancel()
        speechAudioPlayer?.stop()
        activeStreamingPlayer?.stop()
        activeStreamingPlayer = nil
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        speechQueue.removeAll()
        speechQueueDrainTask?.cancel(); speechQueueDrainTask = nil
        streamingSpeechPrefetch.removeAll()
        streamingSpeechTexts.removeAll()
        streamingSpeechNextIndex = 0
        streamingSpeechNextToPlay = 0
        streamingSpeechFirstSampleRate = 0
        streamingSpeechEnded = false
        streamingSpeechPlayer = nil
        streamingSpeechConfig = (provider, endpoint, apiKey, persona)
        isSpeaking = true
        setOutputStatus("正在发声（流式）")
        startStreamingSpeechDrain(generation: gen)
    }

    /// 为窗口内 [nextToPlay, nextToPlay+W) 范围已登记文本、还没起预取的句子启动并行预取。
    private func topUpStreamingPrefetch() {
        guard let cfg = streamingSpeechConfig else { return }
        var index = streamingSpeechNextToPlay
        let upper = streamingSpeechNextToPlay + streamingSpeechPrefetchWindow
        while index < streamingSpeechNextIndex && index < upper {
            if streamingSpeechPrefetch[index] == nil, let text = streamingSpeechTexts[index] {
                streamingSpeechPrefetch[index] = Task.detached(priority: .userInitiated) {
                    try await VoiceIOManager.fetchSpeechAudioResilient(text: text, provider: cfg.provider, endpoint: cfg.endpoint, apiKey: cfg.apiKey, persona: cfg.persona)
                }
            }
            index += 1
        }
    }

    /// drainer:窗口内并行预取 → 按句序取来 → 偶数对齐 + 采样率校验 → 背靠背灌进持续播放器(首句创建)。
    private func startStreamingSpeechDrain(generation gen: Int) {
        streamingSpeechDrainTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.speechGeneration == gen {
                self.topUpStreamingPrefetch()
                // 没有更多句子且已全部入队 → 排空收口。
                if self.streamingSpeechEnded, self.streamingSpeechNextToPlay >= self.streamingSpeechNextIndex {
                    if let player = self.streamingSpeechPlayer { await player.finishAndDrain() }
                    break
                }
                // 下一句还没登记(还没 feed)→ 短等再看。
                guard let task = self.streamingSpeechPrefetch[self.streamingSpeechNextToPlay] else {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    continue
                }
                let wav: Data
                do {
                    wav = try await task.value
                } catch is CancellationError {
                    break
                } catch {
                    lingShuControlLog("TTS 无缝流式 seg#\(self.streamingSpeechNextToPlay) 合成失败跳过: \(VoiceIOManager.shortFailureReason(error))")
                    self.dropStreamingSegment()
                    continue
                }
                guard self.speechGeneration == gen, !Task.isCancelled else { break }
                let index = self.streamingSpeechNextToPlay
                self.dropStreamingSegment()

                // 主线程只做廉价协调:取首段采样率基准 + 现有播放器引用 + 电平回灌闭包。
                let firstRate = self.streamingSpeechFirstSampleRate
                let existing = self.streamingSpeechPlayer
                let levelSink: @Sendable (Float) -> Void = { [weak self] level in
                    Task { @MainActor in self?.outputLevel = level }
                }
                // **重活(WAV 解析 + 偶数对齐 + 建 float buffer + enqueue,含两次逐样本循环)放后台线程**——
                // 绝不在主线程做,否则主线程一忙(如在岗周期感知)就喂不上 PCM → 引擎欠载 → 卡顿(实测在岗卡顿根因)。
                let outcome = await Task.detached(priority: .userInitiated) {
                    VoiceIOManager.renderStreamingSegment(
                        wav: wav, firstSampleRate: firstRate, existingPlayer: existing, onOutputLevel: levelSink
                    )
                }.value
                guard self.speechGeneration == gen, !Task.isCancelled else { break }
                if self.streamingSpeechFirstSampleRate == 0, outcome.sampleRate > 0 {
                    self.streamingSpeechFirstSampleRate = outcome.sampleRate
                }
                if let player = outcome.player, self.streamingSpeechPlayer == nil {
                    self.streamingSpeechPlayer = player
                    self.cloudVoiceDegradedReason = nil   // 拿到云端音频,清降级标记
                }
                if !outcome.ok {
                    lingShuControlLog("TTS 无缝流式 seg#\(index) 跳过(WAV 头无效/采样率不符)")
                }
            }
            // 收口:仅当仍是当前代次才翻转状态(被新发声取代则不动,防误清 isSpeaking)。
            guard let self else { return }
            if self.speechGeneration == gen {
                self.streamingSpeechPlayer = nil
                self.isSpeaking = false
                self.setOutputStatus(self.outputStandbyStatus(for: self.speechOutputProvider))
            }
            self.streamingSpeechDrainTask = nil
        }
    }

    /// 带**软超时 + 重试**的单句取音:服务端偶发抖动时(一句话 TTS 本应几秒,偶尔卡几十秒),
    /// 不再死等到网关 20–60s,而是 15s 软超时即判失败、退避后重试 1 次——绝大多数偶发抖动第二次就回来,不再漏句。
    /// 真持续慢(两次都超 15s)才放弃那句(drainer 跳过)。
    nonisolated static func fetchSpeechAudioResilient(
        text: String,
        provider: LingShuSpeechOutputProviderDescriptor,
        endpoint: String,
        apiKey: String,
        persona: LingShuSpeechPersona
    ) async throws -> Data {
        var lastError: Error?
        for attempt in 1...2 {
            if Task.isCancelled { throw CancellationError() }
            do {
                return try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        try await fetchSpeechAudio(text: text, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)   // 15s 软超时
                        throw LingShuVoiceError.embeddedRuntimeLaunchFailed("单句 TTS 软超时(15s)")
                    }
                    defer { group.cancelAll() }   // 谁先回就取消另一个(成功则停超时;超时则取消请求)
                    guard let result = try await group.next() else {
                        throw LingShuVoiceError.embeddedRuntimeLaunchFailed("单句 TTS 无音频")
                    }
                    return result
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 250_000_000) }   // 退避 0.25s 再重试
            }
        }
        throw lastError ?? LingShuVoiceError.embeddedRuntimeLaunchFailed("单句 TTS 失败")
    }

    /// 把一段 WAV 渲染并灌进播放器——**纯逻辑、nonisolated,必须在后台线程跑**(含两次逐样本循环:转 float + 算电平,
    /// 是主线程音频卡顿的重活)。返回(可能新建的)播放器 + 采样率 + 是否成功。播放器线程安全(锁),后台 enqueue 安全。
    /// 主线程只负责协调(取句序/更新引用),重活全在这里 off-main——主线程再忙也不会饿死音频喂数据。
    nonisolated static func renderStreamingSegment(
        wav: Data,
        firstSampleRate: Double,
        existingPlayer: LingShuStreamingPCMPlayer?,
        onOutputLevel: @escaping @Sendable (Float) -> Void
    ) -> (player: LingShuStreamingPCMPlayer?, sampleRate: Double, ok: Bool) {
        let bytes = [UInt8](wav)
        guard let located = LingShuStreamingWAVHeader.locate(in: bytes), located.pcmStart < bytes.count else {
            return (existingPlayer, firstSampleRate, false)
        }
        // 采样率一致性:首段定基准,后续段不符则跳过(否则按首段固定 format 播 = 音高错/噪音)。
        if firstSampleRate != 0, abs(located.sampleRate - firstSampleRate) > 1 {
            return (existingPlayer, firstSampleRate, false)
        }
        // 每段**独立偶数对齐**:16-bit 样本必须偶数字节,否则经播放器 leftover 串到下一段 → 错位 → 噪音。
        var pcm = Data(bytes[located.pcmStart...])
        if pcm.count % 2 != 0 { pcm = pcm.prefix(pcm.count - 1) }
        guard pcm.count >= 2 else { return (existingPlayer, located.sampleRate, false) }

        var player = existingPlayer
        if player == nil {
            guard let created = LingShuStreamingPCMPlayer(sampleRate: located.sampleRate, onOutputLevel: onOutputLevel) else {
                return (nil, located.sampleRate, false)
            }
            try? created.start()
            player = created
        }
        player?.enqueue(pcm16: pcm)
        return (player, located.sampleRate, true)
    }

    /// 当前句出队(已取走或失败):清掉文本与预取,推进到下一句。
    private func dropStreamingSegment() {
        streamingSpeechPrefetch.removeValue(forKey: streamingSpeechNextToPlay)
        streamingSpeechTexts.removeValue(forKey: streamingSpeechNextToPlay)
        streamingSpeechNextToPlay += 1
    }
}
