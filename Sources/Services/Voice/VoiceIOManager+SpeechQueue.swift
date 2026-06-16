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

    /// 排队播报：供流式分句早读使用——不打断正在播的句子，按顺序续读。
    /// 与 speak(_:) 的"替换式"语义不同，整段重播仍走 speak(_:)。
    func speakQueued(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
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
