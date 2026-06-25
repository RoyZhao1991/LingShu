import Foundation

/// 演示翻页**预合成流水线**:消除「翻页时卡进『处理中』停顿几秒」。
///
/// 根因:云端 CosyVoice2 是**现合成**——每页 `speak()` 才发起 TTS,短句首包也要 3-4s。页内多段已有窗口预取(无缝),
/// 但**页与页之间**没人提前合成下一页 → 每翻一页都现等首包 = 停顿。
///
/// 解法:当前页正在念时,后台把**下一页前几段**讲稿 WAV 先合成好缓存;翻到下一页发声时,前几段命中缓存即时起播、
/// 其余段在播放中按窗口续取(背靠背无缝)。**只预合成前几段**=并发可控,长讲稿(十几段)也不会一次性打爆服务端。
/// 复用现成原语 `fetchSpeechAudioResilient`(每段软超时+重试取音)+ `renderStreamingSegment`(段间不静音)。
/// **不碰核心 `speak()`**,只在演示路径用本文件方法。
@MainActor
extension VoiceIOManager {

    /// 预合成时领先几段(够即时起播,又不一次性发太多并发 TTS)。
    private var presentationPrefetchLead: Int { 3 }

    /// 云端流式发声当前是否可用(有起播延迟、值得预取);本机嗓/英文嗓即时,无需预取。
    private var cloudStreamingSpeechAvailable: Bool {
        let provider = speechOutputProvider
        let endpoint = speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = resolvedSpeechOutputAPIKey(for: provider)
        return provider.supportsStreaming
            && provider.kind != .appleSpeech
            && voiceLanguage != .english
            && !endpoint.isEmpty
            && !(provider.kind == .dataNetSpeakerTTS && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// 预合成一段讲稿的**前几段**(演示翻页用),按文本缓存待播。同段重复调用幂等。
    func prefetchSpeech(_ text: String) {
        let cleaned = Self.strippedForSpeech(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cloudStreamingSpeechAvailable else { return }
        if presentationPrefetch[cleaned] != nil { return }   // 已在预取同段
        // 防陈旧累积(切档/拖动跳页会留下没消费的项):超过几条就整体清掉重来。正常只有 1-2 条(当前页待消费 + 下一页)。
        if presentationPrefetch.count >= 4 { cancelPrefetchedSpeech() }
        let provider = speechOutputProvider
        let endpoint = speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = resolvedSpeechOutputAPIKey(for: provider)
        let persona = speechPersona
        let parts = LingShuSpeechSegmenter.segments(from: cleaned)
        let segs = parts.isEmpty ? [cleaned] : parts
        let lead = min(presentationPrefetchLead, segs.count)
        let leadTasks = (0..<lead).map { i -> Task<Data, Error> in
            let seg = segs[i]
            return Task.detached(priority: .userInitiated) {
                try await VoiceIOManager.fetchSpeechAudioResilient(text: seg, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
            }
        }
        presentationPrefetch[cleaned] = (segs, leadTasks)
        lingShuControlLog("演示预合成下一页 前\(lead)/\(segs.count)段 文本「\(cleaned.prefix(24))」")
    }

    /// 取消并清空所有预取(演示停止/退出/打断时调,别让在飞的合成空耗)。
    func cancelPrefetchedSpeech() {
        presentationPrefetch.values.forEach { $0.leadTasks.forEach { $0.cancel() } }
        presentationPrefetch.removeAll()
    }

    /// **演示专用发声**:命中预合成(前几段已合成)→ 即时起播、其余段播放中续取;未命中 → 退回正常 `speak()` 现合成。
    func speakPresentationNarration(_ text: String) {
        let cleaned = Self.strippedForSpeech(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard let entry = presentationPrefetch.removeValue(forKey: cleaned) else {
            speak(text)   // 没命中(首页/切档重生成/本机嗓)→ 正常现合成
            return
        }
        guard cloudStreamingSpeechAvailable else { entry.leadTasks.forEach { $0.cancel() }; speak(text); return }
        lingShuControlLog("speak(整段·预取命中) 段数=\(entry.segs.count) 文本「\(cleaned.prefix(24))」")
        // 接管发声代次(沿用核心 speak 的「过期音频不出声」机制),停掉先前在飞的发声防双声线。
        speechGeneration &+= 1
        let gen = speechGeneration
        activeSpeechTask?.cancel()
        speechAudioPlayer?.stop()
        activeStreamingPlayer?.stop(); activeStreamingPlayer = nil
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = true
        setOutputStatus("正在发声（流式·预合成）")
        let provider = speechOutputProvider
        let endpoint = speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = resolvedSpeechOutputAPIKey(for: provider)
        let persona = speechPersona
        activeSpeechTask = Task { @MainActor [weak self] in
            await self?.playPresentationSegments(entry.segs, leadTasks: entry.leadTasks,
                                                 provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona, generation: gen)
        }
    }

    /// 把整页各段背靠背灌进**一个**持续 PCM 播放器(段间不排空到静音):前几段用预合成好的任务(即时),其余段按窗口续取。
    /// 与 `speakSegmentsContinuously` 同口径(重活全在后台线程),只是前几段不必现等。
    private func playPresentationSegments(_ segs: [String], leadTasks: [Task<Data, Error>],
                                          provider: LingShuSpeechOutputProviderDescriptor, endpoint: String, apiKey: String,
                                          persona: LingShuSpeechPersona, generation gen: Int) async {
        defer {
            if speechGeneration == gen {   // 仍是当前代次才收口,别把被取代的新发声 isSpeaking 误清
                isSpeaking = false
                setOutputStatus(outputStandbyStatus(for: provider))
            }
        }
        var pending: [Int: Task<Data, Error>] = [:]
        for (i, task) in leadTasks.enumerated() { pending[i] = task }   // 前几段已预合成
        let window = min(8, segs.count)
        var nextToPrefetch = leadTasks.count
        func prefetch(_ index: Int) {
            guard index < segs.count, pending[index] == nil else { return }
            let seg = segs[index]
            pending[index] = Task.detached(priority: .userInitiated) {
                try await VoiceIOManager.fetchSpeechAudioResilient(text: seg, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
            }
        }
        func topUp() {
            while nextToPrefetch < segs.count, pending.count < window { prefetch(nextToPrefetch); nextToPrefetch += 1 }
        }
        topUp()

        var player: LingShuStreamingPCMPlayer?
        var firstRate: Double = 0
        let levelSink: @Sendable (Float) -> Void = { [weak self] level in Task { @MainActor in self?.outputLevel = level } }
        defer { pending.values.forEach { $0.cancel() } }

        for index in 0..<segs.count {
            if Task.isCancelled || speechGeneration != gen { break }
            if pending[index] == nil { prefetch(index) }
            guard let task = pending.removeValue(forKey: index) else { continue }
            let wav: Data
            do {
                wav = try await task.value
            } catch is CancellationError {
                break
            } catch {
                topUp()
                continue   // 单段失败只跳过(绝不抛错触发本机兜底 → 双声线)
            }
            topUp()
            guard speechGeneration == gen, !Task.isCancelled else { break }
            let existing = player
            let rate = firstRate
            let outcome = await Task.detached(priority: .userInitiated) {
                VoiceIOManager.renderStreamingSegment(wav: wav, firstSampleRate: rate, existingPlayer: existing, onOutputLevel: levelSink)
            }.value
            guard speechGeneration == gen, !Task.isCancelled else { break }
            if firstRate == 0, outcome.sampleRate > 0 { firstRate = outcome.sampleRate }
            if let created = outcome.player, player == nil {
                player = created
                activeStreamingPlayer = created
                cloudVoiceDegradedReason = nil
            }
        }
        if let player, speechGeneration == gen, !Task.isCancelled { await player.finishAndDrain() }
        if activeStreamingPlayer === player { activeStreamingPlayer = nil }
    }
}
