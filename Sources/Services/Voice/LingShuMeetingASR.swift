import Foundation
import Speech
import AVFoundation

/// 会议语音识别(第 2 块:采集 → ASR)。
///
/// 把 `LingShuSystemAudioCapture` 抓到的系统音频 PCM 喂进 SFSpeechRecognizer,得到实时转写。
/// 用户已选「允许云端转写」,故不强制 on-device(可用 Apple 服务端,zh-CN 更稳)。
/// 这是第 2 块的「听 → 转写」闭环;滚动累积/多人区分/纪要是第 3 块,基于此扩展。
final class LingShuMeetingASR: @unchecked Sendable {
    static let shared = LingShuMeetingASR()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isRunning = false
    private(set) var transcript = ""
    private(set) var lastError: String?
    private(set) var appendedChunks = 0

    private init() {}

    func start() {
        guard !isRunning else { return }
        lastError = nil
        transcript = ""
        appendedChunks = 0

        SFSpeechRecognizer.requestAuthorization { _ in }
        guard let recognizer else {
            lastError = "无 zh-CN 识别器"
            return
        }
        guard recognizer.isAvailable else {
            lastError = "识别器当前不可用(可能未授权语音识别或离线)"
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.transcript = result.bestTranscription.formattedString
            }
            if let error {
                self.lastError = error.localizedDescription
            }
        }
        isRunning = true
        lingShuControlLog("meeting ASR started")
    }

    /// 接收一帧系统音频 PCM(Float32 单声道)。
    func appendPCM(_ samples: [Float], sampleRate: Double) {
        guard isRunning, let request, !samples.isEmpty else { return }
        guard
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channel[0].update(from: base, count: samples.count)
                }
            }
        }
        request.append(buffer)
        appendedChunks += 1
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
        lingShuControlLog("meeting ASR stopped (chunks=\(appendedChunks), len=\(transcript.count))")
    }

    var statusSnapshot: [String: Any] {
        [
            "isRunning": isRunning,
            "appendedChunks": appendedChunks,
            "transcriptLength": transcript.count,
            "transcript": transcript,
            "lastError": lastError ?? ""
        ]
    }
}
