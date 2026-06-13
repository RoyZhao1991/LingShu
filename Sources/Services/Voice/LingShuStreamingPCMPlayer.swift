@preconcurrency import AVFoundation
import Foundation

/// 流式 PCM 播放器：边收边播，首块音频一到就出声——豆包式超低延迟语音流的播放端。
///
/// 数据网关 `/swds-speaker-tts/stream` 回的是 `wav-pcm-chunked`（一个占位长度的 WAV 头 + 持续的 16-bit PCM 流）。
/// `AVAudioPlayer` 要完整容器、做不到流式；这里用 `AVAudioEngine + AVAudioPlayerNode`，把陆续到达的 PCM 块
/// 转成 float buffer 不断 schedule 进播放节点，引擎自动把源采样率转到硬件采样率。
final class LingShuStreamingPCMPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var outstanding = 0
    private var inputEnded = false
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private var leftover = Data()
    private var started = false
    private var stopped = false

    init?(sampleRate: Double) {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate > 0 ? sampleRate : 16000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.format = fmt
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    func start() throws {
        guard !started else { return }
        engine.prepare()
        try engine.start()
        node.play()
        started = true
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return started && !stopped
    }

    /// 喂入一段 16-bit 小端 PCM 原始字节：补齐 16-bit 对齐后转 float buffer 排队播放。
    func enqueue(pcm16 chunk: Data) {
        lock.lock()
        if stopped { lock.unlock(); return }
        var data = leftover + chunk
        leftover = Data()
        if data.count % 2 != 0 {
            leftover = data.suffix(1)
            data = data.prefix(data.count - 1)
        }
        lock.unlock()

        guard !data.isEmpty, let buffer = makeBuffer(from: data) else { return }

        lock.lock()
        guard !stopped else { lock.unlock(); return }
        outstanding += 1
        lock.unlock()

        node.scheduleBuffer(buffer, completionHandler: { [weak self] in
            self?.bufferCompleted()
        })
    }

    /// 输入流结束后，等所有已排队 buffer 真正播完（被 stop 打断时也会立即返回）。
    func finishAndDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            inputEnded = true
            if stopped || outstanding == 0 {
                lock.unlock()
                continuation.resume()
                return
            }
            drainContinuation = continuation
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let continuation = drainContinuation
        drainContinuation = nil
        outstanding = 0
        leftover = Data()
        lock.unlock()

        guard !wasStopped else { continuation?.resume(); return }
        node.stop()
        engine.stop()
        continuation?.resume()
    }

    private func bufferCompleted() {
        lock.lock()
        outstanding = max(0, outstanding - 1)
        let done = inputEnded && outstanding == 0
        let continuation = done ? drainContinuation : nil
        if done { drainContinuation = nil }
        lock.unlock()
        continuation?.resume()
    }

    private func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let destination = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                let value = Float(Int16(littleEndian: samples[index])) / 32768.0
                destination[index] = max(-1, min(1, value))
            }
        }
        return buffer
    }
}

/// 解析流式 WAV 头：从已到字节里定位 PCM 起点与采样率。头不全返回 nil（等更多字节）。
enum LingShuStreamingWAVHeader {
    /// 返回 (采样率, PCM 数据起始下标)。找不到 `data` 块（头还没收全）返回 nil。
    static func locate(in bytes: [UInt8]) -> (sampleRate: Double, pcmStart: Int)? {
        guard bytes.count >= 12,
              match(bytes, at: 0, ascii: "RIFF"),
              match(bytes, at: 8, ascii: "WAVE") else {
            // 不是 WAV（理论上网关回 wav-pcm-chunked，这里只兜底）：收够一点就当 16kHz 裸 PCM。
            return bytes.count >= 64 ? (16000, 0) : nil
        }
        var sampleRate = 16000.0
        if let fmtIndex = indexOf(ascii: "fmt ", in: bytes), fmtIndex + 16 <= bytes.count {
            let rateOffset = fmtIndex + 8 + 4   // fmt 标签(4)+块长(4)+audioFormat(2)+channels(2) 后是 sampleRate(4)
            if rateOffset + 4 <= bytes.count {
                sampleRate = Double(readUInt32LE(bytes, at: rateOffset))
            }
        }
        if let dataIndex = indexOf(ascii: "data", in: bytes), dataIndex + 8 <= bytes.count {
            return (sampleRate, dataIndex + 8)   // PCM 紧跟 "data"(4)+占位长度(4) 之后
        }
        return nil
    }

    private static func match(_ bytes: [UInt8], at offset: Int, ascii: String) -> Bool {
        let pattern = Array(ascii.utf8)
        guard offset + pattern.count <= bytes.count else { return false }
        return Array(bytes[offset..<offset + pattern.count]) == pattern
    }

    private static func indexOf(ascii: String, in bytes: [UInt8]) -> Int? {
        let pattern = Array(ascii.utf8)
        guard pattern.count <= bytes.count else { return nil }
        for start in 0...(bytes.count - pattern.count) where Array(bytes[start..<start + pattern.count]) == pattern {
            return start
        }
        return nil
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
