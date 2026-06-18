@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
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
    private var started = false        // 引擎已启动
    private var nodePlaying = false    // 播放节点已起播(过了起播预缓冲门槛)
    private var primedFrames: AVAudioFrameCount = 0   // 起播前已排入、累计的预缓冲帧数
    private let primeThresholdFrames: AVAudioFrameCount
    private var stopped = false
    private let onOutputLevel: (@Sendable (Float) -> Void)?
    private var pendingOutputLevel: Float = 0

    init?(sampleRate: Double, onOutputLevel: (@Sendable (Float) -> Void)? = nil) {
        let rate = sampleRate > 0 ? sampleRate : 16000
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.format = fmt
        // 起播预缓冲门槛 ≈ 0.4s:先攒够这么多 PCM 再出声,给网络/合成抖动留余量。
        // 根治"前面一字一卡、后半段才顺"——首块即播时队列见底就饿出逐字静音间隔。
        self.primeThresholdFrames = AVAudioFrameCount(rate * 0.4)
        self.onOutputLevel = onOutputLevel
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    func start() throws {
        guard !started else { return }
        applyPreferredOutputDevice()   // 会议模式:把 TTS 定向到灵枢虚拟麦克风(否则走系统默认输出)
        engine.prepare()
        try engine.start()
        started = true
        // 注意:这里**不** node.play()——等预缓冲攒够(或输入结束)再起播。
        // scheduleBuffer 在节点未播放时也能正常入队,play() 一调即无缝按序播出。
    }

    /// 安全起播:`AVAudioPlayerNode.play()` 在引擎未运行时会抛 ObjC 异常(`required condition is false: IsRunning()`),
    /// 直接 abort 整个进程,且 Swift try/catch 兜不住。这里在锁内先确认引擎在运行才 play——引擎被系统
    /// (音频路由/设备变更触发 AVAudioEngineConfigurationChange、被拔设备)或并发 stop 停掉时,先尝试重启;
    /// 重启不了就放弃本次起播(顶多这段不出声),绝不让未捕获异常把 App 崩掉。
    /// 这是覆盖"所有令引擎停摆诱因"的通用防护,不针对任何具体场景。
    private func safePlay() {
        lock.lock()
        defer { lock.unlock() }
        guard started, !stopped else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }   // 重启失败就放弃本次,不崩
        }
        guard engine.isRunning else { return }
        node.play()
    }

    /// 若设置了首选输出设备(如虚拟麦),把引擎输出单元定向到它;否则用系统默认。
    private func applyPreferredOutputDevice() {
        guard var deviceID = LingShuAudioRouting.preferredOutputDeviceID,
              let unit = engine.outputNode.audioUnit else { return }
        _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &deviceID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
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

        guard !data.isEmpty else { return }
        let level = Self.normalizedPCM16Level(from: data)
        guard let buffer = makeBuffer(from: data) else { return }

        lock.lock()
        guard !stopped else { lock.unlock(); return }
        outstanding += 1
        lock.unlock()

        node.scheduleBuffer(buffer, completionHandler: { [weak self] in
            self?.bufferCompleted()
        })

        // 起播预缓冲:未起播时累计帧数,够门槛才真正 play();之后保持播放,后续块无缝续上。
        var startNow = false
        var emitLevel = false
        lock.lock()
        pendingOutputLevel = level
        if started, !nodePlaying, !stopped {
            primedFrames += buffer.frameLength
            if primedFrames >= primeThresholdFrames { nodePlaying = true; startNow = true }
        }
        emitLevel = nodePlaying
        lock.unlock()
        if startNow { safePlay() }
        if emitLevel { onOutputLevel?(level) }
    }

    /// 输入流结束后，等所有已排队 buffer 真正播完（被 stop 打断时也会立即返回）。
    /// 还没起播就强制起播(同步,锁不跨 await)。输入结束/短句总时长 < 预缓冲门槛时用,避免卡在预缓冲里永不出声。
    private func forceStartPlaybackIfNeeded() {
        var startNow = false
        var level: Float = 0
        lock.lock()
        if started, !nodePlaying, !stopped, outstanding > 0 {
            nodePlaying = true
            startNow = true
            level = pendingOutputLevel
        }
        lock.unlock()
        if startNow {
            safePlay()
            onOutputLevel?(level)
        }
    }

    func finishAndDrain() async {
        forceStartPlaybackIfNeeded()
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
        pendingOutputLevel = 0
        lock.unlock()

        guard !wasStopped else { continuation?.resume(); return }
        node.stop()
        engine.stop()
        onOutputLevel?(0)
        continuation?.resume()
    }

    private func bufferCompleted() {
        lock.lock()
        outstanding = max(0, outstanding - 1)
        let done = inputEnded && outstanding == 0
        let becameEmpty = outstanding == 0
        let continuation = done ? drainContinuation : nil
        if done { drainContinuation = nil }
        lock.unlock()
        if becameEmpty { onOutputLevel?(0) }
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

    private static func normalizedPCM16Level(from data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                let value = Float(Int16(littleEndian: samples[index])) / 32768.0
                sum += value * value
            }
        }
        let rms = (sum / Float(sampleCount)).squareRoot()
        return min(1, max(0, rms * 5.5))
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
