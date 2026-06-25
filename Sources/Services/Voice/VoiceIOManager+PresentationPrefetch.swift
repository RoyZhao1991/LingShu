import Foundation

/// 演示翻页**预合成流水线**:消除「翻页时卡进『处理中』停顿几秒」。
///
/// 根因:云端 CosyVoice2 是**现合成**——每页 `speak()` 才发起 TTS,短句首包也要 3-4s。页内多段已有预取(无缝),
/// 但**页与页之间**没人提前合成下一页 → 每翻一页都现等首包 = 停顿。
///
/// 解法:当前页正在念时,后台把**下一页**讲稿各段 WAV 先合成好缓存;翻到下一页发声时命中缓存、即时起播,
/// 把页间停顿从「3-9s 现合成」降到「<1s 渲染已合成音频」。复用现成原语 `fetchSpeechAudioResilient`(每段软超时+重试取音)
/// + `renderStreamingSegment`(背靠背灌进同一持续播放器,段间不静音)。**不碰核心 `speak()`**,只在演示路径用本文件方法。
@MainActor
extension VoiceIOManager {

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

    /// 预合成一段讲稿(演示翻页用):分段后各段并行后台合成,缓存待播。同段重复调用幂等。
    func prefetchSpeech(_ text: String) {
        let cleaned = Self.strippedForSpeech(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cloudStreamingSpeechAvailable else { return }
        if presentationPrefetchText == cleaned, presentationPrefetchTasks != nil { return }   // 已在预取同段
        presentationPrefetchTasks?.forEach { $0.cancel() }
        let provider = speechOutputProvider
        let endpoint = speechOutputEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = resolvedSpeechOutputAPIKey(for: provider)
        let persona = speechPersona
        let parts = LingShuSpeechSegmenter.segments(from: cleaned)
        let segs = parts.isEmpty ? [cleaned] : parts
        presentationPrefetchText = cleaned
        presentationPrefetchTasks = segs.map { seg in
            Task.detached(priority: .userInitiated) {
                try await VoiceIOManager.fetchSpeechAudioResilient(text: seg, provider: provider, endpoint: endpoint, apiKey: apiKey, persona: persona)
            }
        }
        lingShuControlLog("演示预合成下一页 段数=\(segs.count) 文本「\(cleaned.prefix(28))」")
    }

    /// 取走某段讲稿的预取结果(文本一致才命中,取走即清槽);未命中返回 nil。
    private func takePrefetchedSpeech(for cleaned: String) -> [Task<Data, Error>]? {
        guard presentationPrefetchText == cleaned, let tasks = presentationPrefetchTasks else { return nil }
        presentationPrefetchText = nil
        presentationPrefetchTasks = nil
        return tasks
    }

    /// 取消并清空预取槽(演示停止/退出时调,别让在飞的合成空耗)。
    func cancelPrefetchedSpeech() {
        presentationPrefetchTasks?.forEach { $0.cancel() }
        presentationPrefetchTasks = nil
        presentationPrefetchText = nil
    }

    /// **演示专用发声**:命中预合成槽 → 直接播已合成各段(起播即时,消翻页停顿);未命中 → 退回正常 `speak()` 现合成。
    func speakPresentationNarration(_ text: String) {
        let cleaned = Self.strippedForSpeech(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard let prefetched = takePrefetchedSpeech(for: cleaned) else {
            speak(text)   // 没命中(首页/切档重生成/本机嗓)→ 正常现合成
            return
        }
        lingShuControlLog("speak(整段·预取命中) 段数=\(prefetched.count) 文本「\(cleaned.prefix(28))」")
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
        activeSpeechTask = Task { @MainActor [weak self] in
            await self?.playPrefetchedSegments(prefetched, provider: provider, generation: gen)
        }
    }

    /// 把已合成好的各段 WAV 背靠背灌进**一个**持续 PCM 播放器播放(段间不排空到静音)。重活(WAV 解析/对齐/建 buffer)
    /// 全在后台线程,主线程只协调——与 `speakSegmentsContinuously` 同口径,只是各段音频已预先合成好、无需现等。
    private func playPrefetchedSegments(_ tasks: [Task<Data, Error>], provider: LingShuSpeechOutputProviderDescriptor, generation gen: Int) async {
        defer {
            if speechGeneration == gen {   // 仍是当前代次才收口,别把被取代的新发声 isSpeaking 误清
                isSpeaking = false
                setOutputStatus(outputStandbyStatus(for: provider))
            }
        }
        var player: LingShuStreamingPCMPlayer?
        var firstRate: Double = 0
        let levelSink: @Sendable (Float) -> Void = { [weak self] level in Task { @MainActor in self?.outputLevel = level } }
        for task in tasks {
            if Task.isCancelled || speechGeneration != gen { task.cancel(); break }
            let wav: Data
            do {
                wav = try await task.value
            } catch is CancellationError {
                break
            } catch {
                continue   // 单段失败只跳过(绝不抛错触发本机兜底 → 双声线)
            }
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
        if let player, speechGeneration == gen { await player.finishAndDrain() }
        if activeStreamingPlayer === player { activeStreamingPlayer = nil }
    }
}
