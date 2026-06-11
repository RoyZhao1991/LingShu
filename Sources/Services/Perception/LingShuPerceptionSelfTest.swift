@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// 单项自检结论：通过 / 降级可用 / 不可用，附真实证据（延迟、电平、分辨率等）。
struct LingShuPerceptionSelfTestItem: Identifiable, Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case pass
        case degraded
        case fail
        case skipped

        var label: String {
            switch self {
            case .pass: "通过"
            case .degraded: "降级可用"
            case .fail: "不可用"
            case .skipped: "跳过"
            }
        }
    }

    var id: String { name }
    var name: String
    var verdict: Verdict
    var detail: String
    var latencyMillis: Int?
}

struct LingShuPerceptionSelfTestReport: Equatable, Sendable {
    var startedAt: Date
    var finishedAt: Date
    var items: [LingShuPerceptionSelfTestItem]

    var passCount: Int { items.filter { $0.verdict == .pass }.count }
    var failCount: Int { items.filter { $0.verdict == .fail }.count }

    var summaryLine: String {
        "感知自检完成：\(passCount)/\(items.count) 项通过" + (failCount > 0 ? "，\(failCount) 项不可用" : "")
    }
}

/// 多模态感知自检：对麦克风、语音识别、语音合成、摄像头、视觉解析、云感知、
/// 认主身份七条链路做真实探测——拉权限状态、起引擎采样、测首帧/首响延迟，
/// 给出可复现的通过/不可用结论，而不是界面上的"已就位"装饰文案。
@MainActor
final class LingShuPerceptionSelfTest {
    /// 跑全量自检。摄像头/麦克风正在被通话占用时，对应项实测改为"复用在线信号"。
    static func run(
        voice: VoiceIOManager,
        vision: VisionIOManager,
        perceptionGateway: LingShuRealtimePerceptionGateway,
        cloudClient: LingShuCloudPerceptionClient?
    ) async -> LingShuPerceptionSelfTestReport {
        let startedAt = Date()
        var items: [LingShuPerceptionSelfTestItem] = []

        items.append(await microphoneCheck(voice: voice))
        items.append(appleSpeechCheck())
        items.append(embeddedASRCheck(voice: voice))
        items.append(await speechSynthesisCheck())
        items.append(await cameraCheck(vision: vision))
        items.append(visionAnalysisCheck(vision: vision))
        items.append(await cloudPerceptionCheck(gateway: perceptionGateway, client: cloudClient))
        items.append(ownerIdentityCheck(gateway: perceptionGateway))

        return .init(startedAt: startedAt, finishedAt: Date(), items: items)
    }

    // MARK: - 各链路实测

    /// 麦克风：权限 + 真实起引擎采样 1.2 秒，看是否收到非零电平。
    private static func microphoneCheck(voice: VoiceIOManager) async -> LingShuPerceptionSelfTestItem {
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authorization == .authorized else {
            return .init(
                name: "麦克风采集",
                verdict: authorization == .notDetermined ? .degraded : .fail,
                detail: authorization == .notDetermined
                    ? "尚未请求过麦克风权限；首次开启语音时会弹授权。"
                    : "麦克风权限被拒绝，需到系统设置→隐私与安全→麦克风重新授权。",
                latencyMillis: nil
            )
        }

        if voice.isRecording {
            let level = voice.inputLevel
            return .init(
                name: "麦克风采集",
                verdict: .pass,
                detail: "正在通话中，复用在线信号：当前输入电平 \(String(format: "%.3f", level))。",
                latencyMillis: nil
            )
        }

        // 独立引擎短采样，不动现有语音状态。
        let probeStart = Date()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            return .init(name: "麦克风采集", verdict: .fail, detail: "没有可用的音频输入设备。", latencyMillis: nil)
        }

        final class LevelBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Float = 0
            func update(_ next: Float) {
                lock.lock(); defer { lock.unlock() }
                value = max(value, next)
            }
            var peak: Float {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }
        let box = LevelBox()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count { sum += channel[index] * channel[index] }
            box.update(count > 0 ? (sum / Float(count)).squareRoot() : 0)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return .init(name: "麦克风采集", verdict: .fail, detail: "音频引擎启动失败：\(error.localizedDescription)", latencyMillis: nil)
        }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        engine.stop()
        input.removeTap(onBus: 0)

        let peak = box.peak
        let elapsed = Int(Date().timeIntervalSince(probeStart) * 1000)
        // 静音房间的底噪通常也 > 0.0005；完全为 0 说明根本没拿到数据。
        if peak <= 0.0001 {
            return .init(
                name: "麦克风采集",
                verdict: .fail,
                detail: "引擎已启动但 1.2s 内没有收到任何有效电平（峰值 \(String(format: "%.5f", peak))），输入链路异常。",
                latencyMillis: elapsed
            )
        }
        return .init(
            name: "麦克风采集",
            verdict: .pass,
            detail: "实测采样 \(Int(format.sampleRate))Hz，1.2s 峰值电平 \(String(format: "%.4f", peak))。",
            latencyMillis: elapsed
        )
    }

    private static func appleSpeechCheck() -> LingShuPerceptionSelfTestItem {
        let authorization = SFSpeechRecognizer.authorizationStatus()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
        let available = recognizer?.isAvailable ?? false
        let onDevice = recognizer?.supportsOnDeviceRecognition ?? false

        if authorization == .authorized && available {
            return .init(
                name: "语音识别（Apple Speech）",
                verdict: .pass,
                detail: onDevice ? "中文识别可用，支持本机离线识别。" : "中文识别可用（在线模式，离线模型未下载）。",
                latencyMillis: nil
            )
        }
        if authorization != .authorized {
            return .init(
                name: "语音识别（Apple Speech）",
                verdict: authorization == .notDetermined ? .degraded : .fail,
                detail: authorization == .notDetermined ? "尚未请求语音识别权限。" : "语音识别权限被拒绝。",
                latencyMillis: nil
            )
        }
        return .init(name: "语音识别（Apple Speech）", verdict: .fail, detail: "zh_CN 识别器当前不可用。", latencyMillis: nil)
    }

    private static func embeddedASRCheck(voice: VoiceIOManager) -> LingShuPerceptionSelfTestItem {
        let status = voice.embeddedASRStatus
        return .init(
            name: "内嵌 ASR（SenseVoice）",
            verdict: status.isAvailable ? .pass : .degraded,
            detail: status.isAvailable
                ? status.activationNote
                : "\(status.compactDiagnostic)；当前由 Apple Speech 兜底。",
            latencyMillis: nil
        )
    }

    /// TTS：离线合成一句话到缓冲，测真实合成耗时；不外放、不依赖网络。
    private static func speechSynthesisCheck() async -> LingShuPerceptionSelfTestItem {
        let start = Date()
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "自检")
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")

        let byteCount: Int = await withCheckedContinuation { continuation in
            final class Accumulator: @unchecked Sendable {
                private let lock = NSLock()
                private var bytes = 0
                private var finished = false
                func add(_ count: Int) {
                    lock.lock(); defer { lock.unlock() }
                    bytes += count
                }
                func finishOnce(_ body: (Int) -> Void) {
                    lock.lock(); defer { lock.unlock() }
                    guard !finished else { return }
                    finished = true
                    body(bytes)
                }
            }
            let accumulator = Accumulator()
            synthesizer.write(utterance) { buffer in
                if let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 {
                    accumulator.add(Int(pcmBuffer.frameLength))
                } else {
                    accumulator.finishOnce { continuation.resume(returning: $0) }
                }
            }
            // 合成卡死的兜底：3 秒强制收口。
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                accumulator.finishOnce { continuation.resume(returning: $0) }
            }
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if byteCount > 0 {
            return .init(
                name: "语音合成（系统 TTS）",
                verdict: .pass,
                detail: "离线合成「自检」产出 \(byteCount) 帧音频。",
                latencyMillis: elapsed
            )
        }
        return .init(name: "语音合成（系统 TTS）", verdict: .fail, detail: "合成 3s 内没有产出音频帧。", latencyMillis: elapsed)
    }

    /// 摄像头：权限 + 实测首帧延迟（已在跑则看最近帧的新鲜度）。
    private static func cameraCheck(vision: VisionIOManager) async -> LingShuPerceptionSelfTestItem {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        guard authorization == .authorized else {
            return .init(
                name: "摄像头采集",
                verdict: authorization == .notDetermined ? .degraded : .fail,
                detail: authorization == .notDetermined
                    ? "尚未请求过摄像头权限；首次开启视觉时会弹授权。"
                    : "摄像头权限被拒绝，需到系统设置重新授权。",
                latencyMillis: nil
            )
        }

        let wasRunning = vision.isCameraRunning
        if !wasRunning {
            do {
                try vision.startCamera()
            } catch {
                return .init(name: "摄像头采集", verdict: .fail, detail: "启动失败：\(error.localizedDescription)", latencyMillis: nil)
            }
        }
        defer {
            if !wasRunning {
                vision.stopCamera()
            }
        }

        let probeStart = Date()
        // 帧分析按 1fps 节流，3.5s 内等一帧新观测。
        while Date().timeIntervalSince(probeStart) < 3.5 {
            if let packet = vision.latestFramePacket, packet.timestamp >= probeStart {
                let elapsed = Int(Date().timeIntervalSince(probeStart) * 1000)
                return .init(
                    name: "摄像头采集",
                    verdict: .pass,
                    detail: "实测取帧 \(packet.width)x\(packet.height)，JPEG \(packet.byteCount / 1024)KB。",
                    latencyMillis: elapsed
                )
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return .init(name: "摄像头采集", verdict: .fail, detail: "摄像头已启动但 3.5s 内没有产出有效帧。", latencyMillis: 3500)
    }

    private static func visionAnalysisCheck(vision: VisionIOManager) -> LingShuPerceptionSelfTestItem {
        guard let observation = vision.latestObservation else {
            return .init(
                name: "视觉解析（人脸/文字/变化）",
                verdict: .skipped,
                detail: "本轮没有可分析的帧（摄像头未产出观测）。",
                latencyMillis: nil
            )
        }
        let age = Date().timeIntervalSince(observation.timestamp)
        return .init(
            name: "视觉解析（人脸/文字/变化）",
            verdict: age < 10 ? .pass : .degraded,
            detail: "最近观测（\(Int(age))s 前）：\(observation.summary)",
            latencyMillis: nil
        )
    }

    /// 云感知：真实调一次 models 列表接口，测可达性与延迟（不送任何感知数据）。
    private static func cloudPerceptionCheck(
        gateway: LingShuRealtimePerceptionGateway,
        client: LingShuCloudPerceptionClient?
    ) async -> LingShuPerceptionSelfTestItem {
        guard let client else {
            return .init(
                name: "云感知路由",
                verdict: .degraded,
                detail: "未配置云感知通道，感知走本地解析（当前路由：\(gateway.activeRoute.displayName)）。",
                latencyMillis: nil
            )
        }

        let start = Date()
        do {
            let models = try await client.listModels()
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return .init(
                name: "云感知路由",
                verdict: .pass,
                detail: "云感知在线：\(models.count) 个感知模型可用（当前路由：\(gateway.activeRoute.displayName)）。",
                latencyMillis: elapsed
            )
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return .init(
                name: "云感知路由",
                verdict: .fail,
                detail: "云感知探测失败：\(error.localizedDescription)；本地解析仍可用。",
                latencyMillis: elapsed
            )
        }
    }

    private static func ownerIdentityCheck(gateway: LingShuRealtimePerceptionGateway) -> LingShuPerceptionSelfTestItem {
        let snapshot = gateway.ownerIdentitySnapshot
        if !snapshot.lockEnabled {
            return .init(
                name: "认主身份锁",
                verdict: .degraded,
                detail: "身份锁未开启；当前实现为本地轻量特征锁（面容关键点 + 声线特征），非云端级声纹/人脸识别。",
                latencyMillis: nil
            )
        }
        return .init(
            name: "认主身份锁",
            verdict: snapshot.faceSampleCount > 0 && snapshot.voiceSampleCount > 0 ? .pass : .degraded,
            detail: "\(snapshot.statusText)；面容样本 \(snapshot.faceSampleCount)、声线样本 \(snapshot.voiceSampleCount)。注意：这是本地轻量特征锁，防误唤醒可以，防有意冒充不行。",
            latencyMillis: nil
        )
    }
}
