import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// 系统音频采集（听会议）。
///
/// 用 ScreenCaptureKit 的 `SCStream` 直接从系统音频「数字」抓取会议里其他人的声音，
/// 不经过麦克风——避免房间噪声、避免抓到自己、为 M2 数字双向路由的「输入侧」打底。
/// `excludesCurrentProcessAudio = true` 确保不录灵枢自己的 TTS（防自听回环）。
///
/// 需要「屏幕录制」权限（TCC kTCCServiceScreenCapture）；首次 startCapture 会触发系统授权框，
/// 用户须在 系统设置 ▸ 隐私与安全性 ▸ 屏幕录制 里勾选灵枢。
final class LingShuSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = LingShuSystemAudioCapture()

    private let sampleQueue = DispatchQueue(label: "com.zhaoroy.lingshu.system-audio")
    private var stream: SCStream?

    private(set) var isCapturing = false
    private(set) var startedAt: Date?
    private(set) var bufferCount = 0
    private(set) var frameCount: Int64 = 0
    private(set) var lastLevel: Float = 0
    private(set) var peakLevel: Float = 0
    private(set) var sampleRate: Double = 0
    private(set) var lastError: String?

    /// 下游 ASR 接口：每帧系统音频回调（Float32 单声道 PCM）。第 3 块接转写时挂载。
    var onPCMChunk: (@Sendable (_ samples: [Float], _ sampleRate: Double) -> Void)?

    private override init() { super.init() }

    var elapsedSeconds: Int {
        guard let startedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    /// 启动系统音频采集。无屏幕录制权限时会抛出，错误记入 lastError。
    func start() async throws {
        if isCapturing { return }
        lastError = nil

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            lastError = "无法获取可共享内容（多半是缺屏幕录制权限）：\(error.localizedDescription)"
            throw error
        }
        guard let display = content.displays.first else {
            let message = "未找到可用显示器，无法建立采集流。"
            lastError = message
            throw NSError(domain: "LingShuSystemAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // 不录灵枢自己的 TTS，防自听回环
        config.sampleRate = 48_000
        config.channelCount = 1
        // SCStream 仍需要视频配置；音频采集场景给最小画面即可。
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
        } catch {
            lastError = "startCapture 失败：\(error.localizedDescription)"
            throw error
        }

        self.stream = stream
        isCapturing = true
        startedAt = Date()
        bufferCount = 0
        frameCount = 0
        lastLevel = 0
        peakLevel = 0
        lingShuControlLog("system-audio capture started")
    }

    func stop() async {
        guard let stream else { isCapturing = false; return }
        try? await stream.stopCapture()
        self.stream = nil
        isCapturing = false
        lingShuControlLog("system-audio capture stopped (buffers=\(bufferCount), frames=\(frameCount))")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        if let format = sampleBuffer.formatDescription, let asbd = format.audioStreamBasicDescription {
            sampleRate = asbd.mSampleRate
        }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                var samples: [Float] = []
                var sumSquares: Double = 0
                var count = 0
                for buffer in audioBufferList {
                    guard let data = buffer.mData else { continue }
                    let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let ptr = data.bindMemory(to: Float.self, capacity: floatCount)
                    samples.reserveCapacity(samples.count + floatCount)
                    for i in 0..<floatCount {
                        let v = ptr[i]
                        samples.append(v)
                        sumSquares += Double(v * v)
                        count += 1
                    }
                }
                guard count > 0 else { return }
                let rms = Float((sumSquares / Double(count)).squareRoot())
                self.bufferCount += 1
                self.frameCount += Int64(count)
                self.lastLevel = rms
                self.peakLevel = max(self.peakLevel, rms)
                self.onPCMChunk?(samples, self.sampleRate)
            }
        } catch {
            // 单帧解析失败不致命，丢弃即可。
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = "采集流中止：\(error.localizedDescription)"
        isCapturing = false
        self.stream = nil
        lingShuControlLog("system-audio stream stopped with error: \(error)")
    }

    var statusSnapshot: [String: Any] {
        [
            "isCapturing": isCapturing,
            "elapsedSeconds": elapsedSeconds,
            "bufferCount": bufferCount,
            "frameCount": frameCount,
            "lastLevel": lastLevel,
            "peakLevel": peakLevel,
            "sampleRate": sampleRate,
            "lastError": lastError ?? ""
        ]
    }
}
