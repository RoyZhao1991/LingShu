import Foundation

// MARK: - 感知路由 Provider 协议

/// 实时感知的远端解析方。返回 nil 表示信号已被吸收（例如音频还在缓冲），
/// 不算失败也不产生态势更新。
protocol LingShuRealtimePerceptionProviding: Sendable {
    var routeID: String { get }
    /// 该信号最小转发间隔（秒）。0 表示不在网关层节流，由 provider 自行决定。
    func minimumForwardInterval(for kind: LingShuPerceptionSignalKind) -> TimeInterval
    func analyze(_ envelope: LingShuPerceptionEnvelope) async throws -> LingShuRealtimePerceptionModelReply?
}

// MARK: - WAV 封装

/// 把裸 PCM16 数据封成 WAV 容器：云端听觉接口无法识别无头的 PCM 流。
enum LingShuWAVEncoder {
    static func encode(pcm16: Data, sampleRate: Int, channels: Int) -> Data {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2

        var data = Data(capacity: 44 + pcm16.count)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&data, UInt32(36 + pcm16.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, 16)
        appendUInt16(&data, 1)
        appendUInt16(&data, UInt16(channels))
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(byteRate))
        appendUInt16(&data, UInt16(blockAlign))
        appendUInt16(&data, 16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, UInt32(pcm16.count))
        data.append(pcm16)
        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

// MARK: - 数据网络云感知 Provider

/// 把感知信封转换为数据网络网关的感知专项调用：
/// - 视频帧 → `swds-vision-fast`（8 秒抽一帧，控制延迟与用量）；
/// - 音频流 → 内部缓冲拼批，凑满一批后封 WAV 调 `swds-realtime-hearing`；
/// - 文本类信号（转写/视觉摘要/语音输出）本地已处理，云端不重复消费。
final class LingShuDataNetPerceptionProvider: LingShuRealtimePerceptionProviding, @unchecked Sendable {
    static let routeID = "datanet-cloud-perception"

    static let route = LingShuPerceptionRoute(
        id: routeID,
        displayName: "云感知 · 数据网络",
        mode: .realtimeModel,
        supportedSignals: LingShuPerceptionSignalKind.allCases
    )

    private let client: LingShuCloudPerceptionClient
    private let videoFrameInterval: TimeInterval
    private let audioBatchSeconds: TimeInterval
    private let audioMinInterval: TimeInterval

    private let lock = NSLock()
    private var pcmBuffer = Data()
    private var bufferSampleRate = 16000
    private var bufferChannels = 1
    private var lastAudioUploadAt = Date.distantPast

    init(
        client: LingShuCloudPerceptionClient,
        videoFrameInterval: TimeInterval = 8,
        audioBatchSeconds: TimeInterval = 4,
        audioMinInterval: TimeInterval = 10
    ) {
        self.client = client
        self.videoFrameInterval = videoFrameInterval
        self.audioBatchSeconds = audioBatchSeconds
        self.audioMinInterval = audioMinInterval
    }

    var routeID: String { Self.routeID }

    func minimumForwardInterval(for kind: LingShuPerceptionSignalKind) -> TimeInterval {
        switch kind {
        case .videoFrame:
            return videoFrameInterval
        case .audioChunk, .audioTranscript, .videoObservation, .speechOutput:
            return 0
        }
    }

    func analyze(_ envelope: LingShuPerceptionEnvelope) async throws -> LingShuRealtimePerceptionModelReply? {
        switch envelope.kind {
        case .videoFrame:
            guard let jpeg = envelope.binaryPayload, !jpeg.isEmpty else { return nil }
            let result = try await client.analyzeImage(
                imageBase64: jpeg.base64EncodedString(),
                prompt: "请解析画面用于实时态势感知：1）一句话场景描述（在哪、正在发生什么）；2）人数与人物可见状态（注意力、疲惫、情绪线索）；3）显著文字与物体；4）风险点。简洁，不要客套。"
            )
            return Self.makeReply(from: result)

        case .audioChunk:
            guard let pcm = envelope.binaryPayload, !pcm.isEmpty else { return nil }
            let sampleRate = Int(envelope.metadata["sampleRate"] ?? "") ?? 16000
            let channels = Int(envelope.metadata["channelCount"] ?? "") ?? 1
            guard let wav = bufferAndDrainAudio(pcm: pcm, sampleRate: sampleRate, channels: channels) else {
                return nil
            }
            let result = try await client.analyzeAudio(audioBase64: wav.base64EncodedString())
            return Self.makeReply(from: result)

        case .audioTranscript, .videoObservation, .speechOutput:
            return nil
        }
    }

    /// 云端感知结果 → 态势摘要。独立成静态方法以便离线测试。
    /// 场景语义（在哪/几个人/什么状态）排第一位——它是情境化回应的关键输入，
    /// OCR 与目标计数只是补充。
    static func makeReply(from result: LingShuCloudPerceptionResult) -> LingShuRealtimePerceptionModelReply {
        var parts: [String] = []
        let semantics = result.semanticSuggestions.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Qwen2.5-VL 的场景语义是情境化回应的主输入，放在态势摘要最前。
        // 优先取结构化 summary 字段；没有就退回摊平后的语义文本。
        if let summary = extractSemanticSummary(result.semanticSuggestions), !summary.isEmpty {
            parts.append("场景：\(summary)")
        } else if !semantics.isEmpty {
            parts.append("场景理解：\(String(semantics.prefix(280)))")
        }
        if !transcript.isEmpty {
            parts.append("听觉转写：\(transcript)")
        }
        if !result.ocrTexts.isEmpty {
            parts.append("画面文字：\(result.ocrTexts.prefix(6).joined(separator: "、"))")
        }
        if result.detectionCount > 0 {
            parts.append("检出对象 \(result.detectionCount) 个")
        }
        if parts.isEmpty {
            parts.append(result.taskType == "audio" ? "本段音频未识别到有效语音" : "画面无显著文字或目标")
        }
        // 语义模块失败必须可见：场景理解是情境化回应的主输入，静默缺失会让
        // "为什么灵枢看不懂场景"变成无法排查的谜。
        if semantics.isEmpty, let semanticsWarning = result.warnings.first(where: { $0.contains("semantics") }) {
            parts.append("（云端场景语义模块异常：\(String(semanticsWarning.prefix(120)))）")
        }

        var metadata: [String: String] = ["taskType": result.taskType, "model": result.model]
        if let tokens = result.totalTokens {
            metadata["totalTokens"] = String(tokens)
        }
        if !result.warnings.isEmpty {
            metadata["warnings"] = result.warnings.joined(separator: ",")
        }

        return LingShuRealtimePerceptionModelReply(
            summary: "云感知：" + parts.joined(separator: "；"),
            confidence: nil,
            transcript: transcript.isEmpty ? nil : transcript,
            intentHint: nil,
            metadata: metadata
        )
    }

    /// 从 semantic_suggestions 的 JSON 串里取 VL 的 summary（场景理解）。
    static func extractSemanticSummary(_ semanticSuggestions: String) -> String? {
        guard let data = semanticSuggestions.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = obj["summary"] as? String else {
            return nil
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 音频拼批：凑满 `audioBatchSeconds` 且距上次上传超过 `audioMinInterval` 才出批。
    /// 返回 nil 表示继续缓冲。
    func bufferAndDrainAudio(pcm: Data, sampleRate: Int, channels: Int, now: Date = Date()) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if sampleRate != bufferSampleRate || channels != bufferChannels {
            pcmBuffer.removeAll()
            bufferSampleRate = sampleRate
            bufferChannels = channels
        }
        pcmBuffer.append(pcm)

        let bytesPerSecond = Double(sampleRate * channels * 2)
        let bufferedSeconds = Double(pcmBuffer.count) / max(bytesPerSecond, 1)
        guard bufferedSeconds >= audioBatchSeconds,
              now.timeIntervalSince(lastAudioUploadAt) >= audioMinInterval else {
            return nil
        }

        let wav = LingShuWAVEncoder.encode(pcm16: pcmBuffer, sampleRate: sampleRate, channels: channels)
        pcmBuffer.removeAll()
        lastAudioUploadAt = now
        return wav
    }
}
