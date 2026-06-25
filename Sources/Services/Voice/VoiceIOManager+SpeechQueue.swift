import Foundation

/// 分句早读队列：流式回复每攒满一句就排队播报，按到达顺序续读——
/// 语音对话不必等整段回复生成完才开口。
@MainActor
extension VoiceIOManager {
    /// 正在播报或还有排队句子未播完：连续通话用它判断"灵枢还在说话"，
    /// 避免分句间隙被误判为播报结束而提前重启麦克风（回声误触发）。
    var isSpeakingOrQueued: Bool {
        isSpeaking || !speechQueue.isEmpty || speechQueueDrainTask != nil || streamingSpeechDrainTask != nil
    }

    /// 阻塞等当前这句念完(供 speak 工具同步返回:演示逐页讲自然停顿)。先等起播(TTS 有起播延迟),
    /// 再等念完;双封顶防卡:起播最多 3s、整句最多 `maxSeconds`(默认 90s),到顶即放行不阻塞 agent 循环。
    /// **演示长页(详细档几百字念 100s+)须传更大的 maxSeconds**,否则 90s 硬闸会把没念完的页切走(实测翻页过早)。
    func awaitPlaybackDone(maxSeconds: Double = 90) async {
        let start = Date()
        while Date().timeIntervalSince(start) < 3, !isSpeakingOrQueued {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        while Date().timeIntervalSince(start) < maxSeconds, isSpeakingOrQueued {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// 排队播报：供流式分句早读使用——不打断正在播的句子，按顺序续读。
    /// 与 speak(_:) 的"替换式"语义不同，整段重播仍走 speak(_:)。
    func speakQueued(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        lingShuControlLog("TTS来源④: 排队朗读 文本「\(cleaned.prefix(40))」")
        speechQueue.append(cleaned)
        drainSpeechQueueIfNeeded()
    }

    private func drainSpeechQueueIfNeeded() {
        guard speechQueueDrainTask == nil else { return }
        speechQueueDrainTask = Task { @MainActor [weak self] in
            defer { self?.speechQueueDrainTask = nil }
            while let self, !Task.isCancelled, !self.speechQueue.isEmpty {
                let sentence = self.speechQueue.removeFirst()
                self.speak(sentence)
                // 等本句起播（最多 2.5s），再等播完，才取下一句。
                var startupTicks = 0
                while !self.isSpeaking && startupTicks < 31 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    startupTicks += 1
                }
                while self.isSpeaking && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }
    }
}
