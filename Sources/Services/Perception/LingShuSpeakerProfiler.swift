import Foundation

/// 说话人画像快照：声线基频、性别推测、置信度。注入对话上下文供模型自然适配语气，
/// 不做任何写死的"男性就说X、女性就说Y"策略——怎么用画像由模型自己判断。
struct LingShuSpeakerProfileSnapshot: Equatable, Sendable {
    var medianPitchHz: Double
    var voicedSampleCount: Int
    var genderLabel: String
    var confidenceLabel: String
    var updatedAt: Date

    /// 没有足够样本时为 nil，调用方据此决定是否注入上下文。
    var promptLine: String? {
        guard voicedSampleCount >= 6 else { return nil }
        return "说话人声线：基频约 \(Int(medianPitchHz))Hz，推测为\(genderLabel)（置信度\(confidenceLabel)，依据 \(voicedSampleCount) 段有效语音）。"
    }
}

/// 声线画像器：对麦克风 PCM16 流做基频估计（自相关法），滚动中位数推测说话人性别。
/// 纯本地、纯信号处理，不留存任何音频；只输出统计画像。
/// 典型基频：成年男声 85~165Hz，成年女声 165~255Hz，165~180Hz 为重叠区报"未定"。
final class LingShuSpeakerProfiler {
    private(set) var recentPitches: [Double] = []
    private var lastVoicedAt = Date.distantPast
    private let maxSamples = 40
    /// 长时间无人说话后画像过期，避免拿上一位说话人的声线套现在的人。
    private let staleInterval: TimeInterval = 180

    func ingest(_ packet: LingShuAudioStreamPacket, now: Date = Date()) {
        guard let pitch = Self.estimatePitch(
            pcm16Data: packet.pcm16Data,
            sampleRate: packet.sampleRate,
            channelCount: packet.channelCount
        ) else { return }

        if now.timeIntervalSince(lastVoicedAt) > staleInterval {
            recentPitches.removeAll()
        }
        lastVoicedAt = now
        recentPitches.append(pitch)
        if recentPitches.count > maxSamples {
            recentPitches.removeFirst(recentPitches.count - maxSamples)
        }
    }

    /// 最近窗口内疑似多位说话人：基频分布出现两个相距 ≥60Hz 的簇
    /// （同一个人正常说话的基频波动远小于此）。
    var multipleSpeakersSuspected: Bool {
        guard recentPitches.count >= 10 else { return false }
        let sorted = recentPitches.sorted()
        let lower = sorted[sorted.count / 10]
        let upper = sorted[(sorted.count * 9) / 10]
        return upper - lower >= 60
    }

    func snapshot(now: Date = Date()) -> LingShuSpeakerProfileSnapshot? {
        guard !recentPitches.isEmpty,
              now.timeIntervalSince(lastVoicedAt) <= staleInterval else { return nil }

        let sorted = recentPitches.sorted()
        let median = sorted[sorted.count / 2]
        let (gender, confidence) = Self.classify(medianPitch: median, sampleCount: recentPitches.count)
        return .init(
            medianPitchHz: median,
            voicedSampleCount: recentPitches.count,
            genderLabel: gender,
            confidenceLabel: confidence,
            updatedAt: lastVoicedAt
        )
    }

    static func classify(medianPitch: Double, sampleCount: Int) -> (gender: String, confidence: String) {
        let gender: String
        switch medianPitch {
        case ..<165: gender = "男声"
        case 180...: gender = "女声"
        default: gender = "未定（声线处于男女重叠区）"
        }
        // 远离重叠区且样本充足才给"高"置信。
        let separation = min(abs(medianPitch - 165), abs(medianPitch - 180))
        let confidence: String
        if gender.hasPrefix("未定") || sampleCount < 12 {
            confidence = "低"
        } else if separation >= 25 && sampleCount >= 20 {
            confidence = "高"
        } else {
            confidence = "中"
        }
        return (gender, confidence)
    }

    /// 自相关基频估计：在 60~400Hz 范围内找归一化自相关峰值。
    /// 返回 nil 表示该段不是有效浊音（太安静或周期性不足）。
    static func estimatePitch(pcm16Data: Data, sampleRate: Double, channelCount: Int) -> Double? {
        guard sampleRate > 0, channelCount > 0 else { return nil }
        let stride = max(1, channelCount)
        var samples: [Double] = []
        samples.reserveCapacity(pcm16Data.count / (2 * stride))
        pcm16Data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let int16Buffer = buffer.bindMemory(to: Int16.self)
            var index = 0
            while index < int16Buffer.count && samples.count < 4096 {
                samples.append(Double(Int16(littleEndian: int16Buffer[index])) / 32768.0)
                index += stride
            }
        }

        let minLag = Int(sampleRate / 400)
        let maxLag = Int(sampleRate / 60)
        guard samples.count > maxLag + 32, minLag >= 2 else { return nil }

        // 能量门限：太安静的段不参与画像。
        var energy = 0.0
        for sample in samples { energy += sample * sample }
        let rms = (energy / Double(samples.count)).squareRoot()
        guard rms > 0.01 else { return nil }

        // 去直流
        let mean = samples.reduce(0, +) / Double(samples.count)
        let centered = samples.map { $0 - mean }
        var zeroLag = 0.0
        for value in centered { zeroLag += value * value }
        guard zeroLag > 0 else { return nil }

        var bestLag = 0
        var bestCorrelation = 0.0
        for lag in minLag...maxLag {
            var correlation = 0.0
            for index in 0..<(centered.count - lag) {
                correlation += centered[index] * centered[index + lag]
            }
            correlation /= zeroLag
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        // 周期性不足（噪声/清音）不计入。
        guard bestCorrelation > 0.5, bestLag > 0 else { return nil }
        return sampleRate / Double(bestLag)
    }
}
