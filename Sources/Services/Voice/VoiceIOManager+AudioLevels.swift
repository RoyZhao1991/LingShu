@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// 音频 tap 的发射节流器。tap 在专用音频线程上串行回调，这里用锁守一下让它在
/// Swift 6 并发下是 Sendable 安全的；只暴露"距上次是否够久"的判断。
private final class AudioTapEmitThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLevel = Date.distantPast
    private var lastChunk = Date.distantPast

    func shouldEmitLevel(at now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(lastLevel) >= 0.05 else { return false }
        lastLevel = now
        return true
    }

    func shouldEmitChunk(at now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(lastChunk) >= 0.2 else { return false }
        lastChunk = now
        return true
    }
}

// 麦克风/播放的实时电平与音频缓冲处理。从 VoiceIOManager 拆出以守住 800 行硬上限。
@MainActor
extension VoiceIOManager {
    /// 输出电平驱动：AVAudioPlayer 路径用真实音量计；Apple 合成器无音量计时用与语音同步的活跃动画值。
    func startOutputMetering() {
        outputMeterTask?.cancel()
        outputMeterTask = Task { @MainActor [weak self] in
            var phase: Float = 0
            while !Task.isCancelled, let self, self.isSpeaking {
                if let player = self.speechAudioPlayer, player.isPlaying {
                    player.updateMeters()
                    let power = player.averagePower(forChannel: 0) // dB，约 -160...0
                    let normalized = max(0, min(1, (power + 50) / 50))
                    self.outputLevel = normalized
                } else {
                    // Apple 合成器：无逐帧音量，用活跃波动表达“正在发声”。
                    phase += 0.5
                    self.outputLevel = 0.35 + 0.4 * abs(sin(phase))
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.outputLevel = 0
        }
    }

    func stopOutputMetering() {
        outputMeterTask?.cancel()
        outputMeterTask = nil
        outputLevel = 0
    }

    nonisolated func makeRecognitionAudioTap(
        box: RecognitionRequestBox,
        onAudioChunk: (@MainActor (LingShuAudioStreamPacket) -> Void)?
    ) -> AVAudioNodeTapBlock {
        // 节流：音频 tap 每个缓冲（~40/s）都跳主线程的话，会让主线程满负荷跑声纹/认主 DSP
        // 把 UI 卡死。电平最多 ~20Hz 刷新（够波形流畅）；音频块最多 ~5Hz 转发（感知/声纹处理本就
        // 不需要每缓冲一次）。真正的根治是把 DSP 移出主线程，这里先把洪泛掐掉。
        let throttle = AudioTapEmitThrottle()
        return { [weak self] buffer, _ in
            box.append(buffer)   // 灌进"当前"请求；每句结束只轮换请求，引擎与 tap 不动
            let now = Date()

            if throttle.shouldEmitLevel(at: now) {
                let level = Self.normalizedRMS(from: buffer)
                Task { @MainActor in
                    self?.inputLevel = level
                }
            }

            if let onAudioChunk,
               throttle.shouldEmitChunk(at: now),
               let packet = Self.makePCM16Packet(from: buffer) {
                Task { @MainActor in
                    onAudioChunk(packet)
                }
            }
        }
    }

    /// 计算缓冲区的归一化 RMS（0...1），轻度压缩后用作波形高度。
    nonisolated static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            let s = channel[i]
            sum += s * s
        }
        let rms = (sum / Float(frames)).squareRoot()
        // 语音 RMS 通常很小，做一次非线性放大映射到可见区间。
        return min(1, max(0, rms * 6))
    }

    nonisolated static func makePCM16Packet(from buffer: AVAudioPCMBuffer) -> LingShuAudioStreamPacket? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        guard frameCount > 0 else { return nil }

        var pcmData = Data(capacity: frameCount * channelCount * MemoryLayout<Int16>.size)

        if let floatData = buffer.floatChannelData {
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    let sample = max(-1.0, min(1.0, floatData[channelIndex][frameIndex]))
                    var intSample = Int16(sample * Float(Int16.max)).littleEndian
                    withUnsafeBytes(of: &intSample) { pcmData.append(contentsOf: $0) }
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    var intSample = int16Data[channelIndex][frameIndex].littleEndian
                    withUnsafeBytes(of: &intSample) { pcmData.append(contentsOf: $0) }
                }
            }
        } else {
            return nil
        }

        return LingShuAudioStreamPacket(
            timestamp: Date(),
            pcm16Data: pcmData,
            sampleRate: buffer.format.sampleRate,
            channelCount: channelCount,
            frameCount: frameCount
        )
    }
}
