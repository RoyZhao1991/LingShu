import Combine
import Foundation

enum LingShuPerceptionSignalKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case audioChunk
    case audioTranscript
    case videoFrame
    case videoObservation
    case speechOutput

    var label: String {
        switch self {
        case .audioChunk: "音频流"
        case .audioTranscript: "语音转写"
        case .videoFrame: "视频帧"
        case .videoObservation: "视觉摘要"
        case .speechOutput: "语音输出"
        }
    }
}

enum LingShuPerceptionProviderMode: String, Codable, Equatable, Sendable {
    case local
    case realtimeModel
    case externalAdapter

    var label: String {
        switch self {
        case .local: "本地解析"
        case .realtimeModel: "模型直连"
        case .externalAdapter: "外部适配"
        }
    }
}

struct LingShuAudioStreamPacket: Equatable, Sendable {
    let timestamp: Date
    let pcm16Data: Data
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int

    var byteCount: Int {
        pcm16Data.count
    }
}

struct LingShuVideoFramePacket: Equatable, Sendable {
    let timestamp: Date
    let jpegData: Data
    let width: Int
    let height: Int

    var byteCount: Int {
        jpegData.count
    }
}

struct LingShuPerceptionEnvelope: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date
    var kind: LingShuPerceptionSignalKind
    var source: String
    var textPayload: String?
    var binaryPayload: Data?
    var metadata: [String: String]
}

struct LingShuRealtimePerceptionEndpoint: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var endpoint: URL
    var apiKey: String
    var protocolName: String
    var supportedSignals: [LingShuPerceptionSignalKind]

    var mode: LingShuPerceptionProviderMode {
        protocolName.lowercased().contains("adapter") ? .externalAdapter : .realtimeModel
    }
}

struct LingShuPerceptionRoute: Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var mode: LingShuPerceptionProviderMode
    var supportedSignals: [LingShuPerceptionSignalKind]

    static let local = LingShuPerceptionRoute(
        id: "local-system-perception",
        displayName: "本地解析",
        mode: .local,
        supportedSignals: LingShuPerceptionSignalKind.allCases
    )
}

struct LingShuRealtimePerceptionModelReply: Codable, Equatable, Sendable {
    var summary: String
    var confidence: Double?
    var transcript: String?
    var intentHint: String?
    var metadata: [String: String]?
}

struct LingShuPerceptionInvocationContract: Equatable, Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data
    var protocolName: String
}

final class LingShuHTTPRealtimePerceptionProvider: LingShuRealtimePerceptionProviding, @unchecked Sendable {
    private let endpoint: LingShuRealtimePerceptionEndpoint
    private let session: URLSession

    var routeID: String { endpoint.id }

    func minimumForwardInterval(for kind: LingShuPerceptionSignalKind) -> TimeInterval {
        switch kind {
        case .audioChunk, .videoFrame:
            return 0.8
        case .audioTranscript, .videoObservation, .speechOutput:
            return 0
        }
    }

    init(
        endpoint: LingShuRealtimePerceptionEndpoint,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    func makeInvocationContract(for envelope: LingShuPerceptionEnvelope) throws -> LingShuPerceptionInvocationContract {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(envelope)
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-LingShu-Protocol": endpoint.protocolName
        ]

        let trimmedAPIKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            headers["Authorization"] = "Bearer \(trimmedAPIKey)"
        }

        return LingShuPerceptionInvocationContract(
            url: endpoint.endpoint,
            method: "POST",
            headers: headers,
            body: body,
            protocolName: endpoint.protocolName
        )
    }

    func analyze(_ envelope: LingShuPerceptionEnvelope) async throws -> LingShuRealtimePerceptionModelReply? {
        let contract = try makeInvocationContract(for: envelope)
        var request = URLRequest(url: contract.url)
        request.httpMethod = contract.method
        request.httpBody = contract.body
        for (key, value) in contract.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw LingShuModelGatewayError.requestFailed(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LingShuRealtimePerceptionModelReply.self, from: data)
    }
}

@MainActor
final class LingShuRealtimePerceptionGateway: ObservableObject {
    @Published private(set) var activeRoute: LingShuPerceptionRoute = .local
    @Published private(set) var availableRoutes: [LingShuPerceptionRoute] = [.local]
    @Published private(set) var statusText = "本地解析"
    @Published private(set) var eventCount = 0
    @Published private(set) var rawForwardedCount = 0
    @Published private(set) var lastEventSummary = "等待感知输入"
    @Published private(set) var lastModelFeedback = ""
    @Published private(set) var latestSnapshot: LingShuPerceptionSituationSnapshot = .idle
    @Published private(set) var ownerIdentitySnapshot: LingShuOwnerIdentitySnapshot

    private var remoteProviders: [String: any LingShuRealtimePerceptionProviding] = [:]
    private var cloudProvider: LingShuDataNetPerceptionProvider?
    private var lastRawForwardAt: [LingShuPerceptionSignalKind: Date] = [:]
    /// 最近一帧（不受转发节流影响），供对话时按需做场景理解。
    private var latestFrameForOnDemand: LingShuVideoFramePacket?
    private var lastSceneUnderstandingAt = Date.distantPast
    private var latestTranscription: LingShuVoiceTranscriptionResult?
    private var latestVisionObservation: LingShuVisionObservation?
    private var latestModelReply: LingShuRealtimePerceptionModelReply?
    private let perceptionThreadCoordinator = LingShuPerceptionThreadCoordinator()
    private let ownerIdentityService: LingShuOwnerIdentityService
    /// 声线画像器：基频统计 → 说话人性别推测，画像注入对话上下文（非写死策略）。
    private let speakerProfiler = LingShuSpeakerProfiler()

    init(ownerIdentityService: LingShuOwnerIdentityService = LingShuOwnerIdentityService()) {
        self.ownerIdentityService = ownerIdentityService
        ownerIdentitySnapshot = ownerIdentityService.currentSnapshot
    }

    var isRemoteRouteActive: Bool {
        activeRoute.mode != .local
    }

    var promptContext: String {
        [ownerIdentitySnapshot.promptContext, speakerProfileLine ?? "", latestSnapshot.promptContext]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    /// 当前说话人声线画像（基频/性别推测）；样本不足或过期时为 nil。
    var speakerProfileLine: String? {
        speakerProfiler.snapshot()?.promptLine
    }

    /// 最近窗口疑似多位说话人（基频双簇），声线寻址闸门据此提高响应门槛。
    var multipleSpeakersSuspected: Bool {
        speakerProfiler.multipleSpeakersSuspected
    }

    /// 最近的视觉环境一句话摘要，供情境上下文引用。
    var latestVisionSummary: String? {
        latestVisionObservation?.summary
    }

    /// 是否存在可注入对话的有效感知信号；为 false 时不要把空态势塞进提示词浪费 token。
    var hasLiveSignals: Bool {
        latestTranscription != nil || latestVisionObservation != nil || latestModelReply != nil
    }

    var ownerIdentityLockEnabled: Bool {
        ownerIdentitySnapshot.lockEnabled
    }

    var isOwnerIdentityLocked: Bool {
        ownerIdentitySnapshot.isLocked
    }

    func setOwnerIdentityLockEnabled(_ enabled: Bool) {
        ownerIdentitySnapshot = ownerIdentityService.setLockEnabled(enabled)
    }

    func beginOwnerEnrollment(ownerName: String) {
        ownerIdentitySnapshot = ownerIdentityService.beginEnrollment(ownerName: ownerName)
    }

    func resetOwnerIdentity() {
        ownerIdentitySnapshot = ownerIdentityService.reset()
    }

    func configureRemoteEndpoints(_ endpoints: [LingShuRealtimePerceptionEndpoint]) {
        remoteProviders = Dictionary(uniqueKeysWithValues: endpoints.map {
            ($0.id, LingShuHTTPRealtimePerceptionProvider(endpoint: $0) as any LingShuRealtimePerceptionProviding)
        })

        rebuildAvailableRoutes(endpointRoutes: endpoints.map {
            LingShuPerceptionRoute(
                id: $0.id,
                displayName: $0.displayName,
                mode: $0.mode,
                supportedSignals: $0.supportedSignals
            )
        })
    }

    /// 注册/注销数据网络云感知路由。传 nil 注销；
    /// 注册时如果当前还停留在本地解析，自动切到云感知。
    func registerCloudPerceptionRoute(client: LingShuCloudPerceptionClient?) {
        if let client {
            let wasUnavailable = cloudProvider == nil
            cloudProvider = LingShuDataNetPerceptionProvider(client: client)
            rebuildAvailableRoutes()
            if wasUnavailable, activeRoute.id == LingShuPerceptionRoute.local.id {
                selectRoute(id: LingShuDataNetPerceptionProvider.routeID)
                statusText = "云感知就绪"
            }
        } else {
            cloudProvider = nil
            rebuildAvailableRoutes()
        }
    }

    private func rebuildAvailableRoutes(endpointRoutes: [LingShuPerceptionRoute]? = nil) {
        let existingEndpointRoutes = endpointRoutes
            ?? availableRoutes.filter { $0.id != LingShuPerceptionRoute.local.id && $0.id != LingShuDataNetPerceptionProvider.routeID }
        let cloudRoutes = cloudProvider == nil ? [] : [LingShuDataNetPerceptionProvider.route]
        availableRoutes = [.local] + cloudRoutes + existingEndpointRoutes

        if !availableRoutes.contains(where: { $0.id == activeRoute.id }) {
            activeRoute = .local
            statusText = LingShuPerceptionRoute.local.mode.label
        }
    }

    private func activeProvider() -> (any LingShuRealtimePerceptionProviding)? {
        if activeRoute.id == LingShuDataNetPerceptionProvider.routeID {
            return cloudProvider
        }
        return remoteProviders[activeRoute.id]
    }

    func selectRoute(id: String) {
        guard let route = availableRoutes.first(where: { $0.id == id }) else { return }
        activeRoute = route
        statusText = route.mode.label
        lastModelFeedback = ""
    }

    func ingestAudioTranscript(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        latestTranscription = LingShuVoiceTranscriptionResult(
            text: trimmed,
            isFinal: isFinal,
            confidence: nil,
            provider: .externalRealtimeAdapter,
            intentHint: nil,
            timestamp: Date()
        )
        refreshSnapshot()

        ingest(.init(
            timestamp: Date(),
            kind: .audioTranscript,
            source: "mac.microphone",
            textPayload: trimmed,
            binaryPayload: nil,
            metadata: ["final": isFinal ? "true" : "false"]
        ))
    }

    func ingestAudioTranscription(_ result: LingShuVoiceTranscriptionResult) {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        latestTranscription = result
        refreshSnapshot()

        var metadata = [
            "final": result.isFinal ? "true" : "false",
            "providerID": result.provider.id,
            "provider": result.provider.displayName,
            "providerKind": result.provider.kind.rawValue,
            "deployment": result.provider.deployment,
            "primaryLanguage": result.provider.primaryLanguage,
            "streaming": result.provider.supportsStreaming ? "true" : "false",
            "localInference": result.provider.supportsLocalInference ? "true" : "false",
            "vad": result.provider.supportsVoiceActivityDetection ? "true" : "false",
            "semanticHints": result.provider.supportsSemanticHints ? "true" : "false"
        ]
        if let confidence = result.confidence {
            metadata["confidence"] = String(format: "%.3f", confidence)
        }
        if let intentHint = result.intentHint {
            metadata["intentHint"] = intentHint
        }

        ingest(.init(
            timestamp: result.timestamp,
            kind: .audioTranscript,
            source: "mac.microphone.\(result.provider.kind.rawValue)",
            textPayload: trimmed,
            binaryPayload: nil,
            metadata: metadata
        ))
    }

    func ingestAudioChunk(_ packet: LingShuAudioStreamPacket) {
        ownerIdentitySnapshot = ownerIdentityService.ingestAudioPacket(packet)

        // 基频自相关较重，每个音频块都在主线程算会卡 UI（用户实测发现的根因）。
        // 放后台线程算，主线程只 await（期间挂起、不阻塞渲染），算完回主线程做极轻的滚动更新。
        let pcm = packet.pcm16Data
        let sampleRate = packet.sampleRate
        let channelCount = packet.channelCount
        Task { @MainActor [weak self] in
            let pitch = await Task.detached(priority: .userInitiated) {
                LingShuSpeakerProfiler.estimatePitch(pcm16Data: pcm, sampleRate: sampleRate, channelCount: channelCount)
            }.value
            self?.speakerProfiler.ingest(pitch: pitch)
        }

        guard shouldForwardRawSignal(.audioChunk) else {
            recordLocal(kind: .audioChunk, summary: "音频流本地保活：\(packet.byteCount) bytes")
            return
        }

        ingest(.init(
            timestamp: packet.timestamp,
            kind: .audioChunk,
            source: "mac.microphone",
            textPayload: nil,
            binaryPayload: packet.pcm16Data,
            metadata: [
                "encoding": "pcm_s16le",
                "sampleRate": String(Int(packet.sampleRate)),
                "channelCount": String(packet.channelCount),
                "frameCount": String(packet.frameCount),
                "byteCount": String(packet.byteCount)
            ]
        ))
    }

    func ingestVisionObservation(_ observation: LingShuVisionObservation) {
        latestVisionObservation = observation
        ownerIdentitySnapshot = ownerIdentityService.ingestVisionObservation(observation)
        refreshSnapshot()

        ingest(.init(
            timestamp: observation.timestamp,
            kind: .videoObservation,
            source: "mac.camera.local-vision",
            textPayload: observation.summary,
            binaryPayload: nil,
            metadata: [
                "faceCount": String(observation.faceCount),
                "recognizedText": observation.recognizedText,
                "brightness": String(format: "%.3f", observation.brightness),
                "motion": String(format: "%.3f", observation.motion),
                "frameSize": "\(observation.frameWidth)x\(observation.frameHeight)"
            ]
        ))
    }

    func ingestVideoFrame(_ packet: LingShuVideoFramePacket) {
        ownerIdentitySnapshot = ownerIdentityService.ingestVideoFrame(packet)
        latestFrameForOnDemand = packet

        guard shouldForwardRawSignal(.videoFrame) else {
            recordLocal(kind: .videoFrame, summary: "视频帧本地保活：\(packet.width)x\(packet.height)")
            return
        }

        ingest(.init(
            timestamp: packet.timestamp,
            kind: .videoFrame,
            source: "mac.camera",
            textPayload: nil,
            binaryPayload: packet.jpegData,
            metadata: [
                "encoding": "jpeg",
                "width": String(packet.width),
                "height": String(packet.height),
                "byteCount": String(packet.byteCount)
            ]
        ))
    }

    func ingestSpeechOutput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        ingest(.init(
            timestamp: Date(),
            kind: .speechOutput,
            source: "mac.speaker",
            textPayload: trimmed,
            binaryPayload: nil,
            metadata: [:]
        ))
    }

    private func ingest(_ envelope: LingShuPerceptionEnvelope) {
        guard activeRoute.supportedSignals.contains(envelope.kind) else {
            recordLocal(kind: envelope.kind, summary: "\(activeRoute.displayName) 不处理 \(envelope.kind.label)")
            return
        }

        eventCount += 1
        let payloadLabel = envelope.textPayload ?? envelope.metadata["byteCount"].map { "\($0) bytes" } ?? "已接收"
        lastEventSummary = "\(envelope.kind.label)：\(payloadLabel)"

        guard activeRoute.mode != .local,
              let provider = activeProvider() else {
            statusText = "本地解析 \(eventCount)"
            return
        }

        statusText = "模型解析中"
        rawForwardedCount += envelope.binaryPayload == nil ? 0 : 1

        Task {
            do {
                if let reply = try await provider.analyze(envelope) {
                    await MainActor.run {
                        self.latestModelReply = reply
                        if envelope.kind == .videoFrame {
                            self.lastSceneUnderstandingAt = Date()
                        }
                        self.refreshSnapshot()
                        self.lastModelFeedback = reply.summary
                        self.statusText = "模型解析在线"
                    }
                } else {
                    // 信号被 provider 吸收（缓冲/不消费），不更新态势。
                    await MainActor.run {
                        self.statusText = "模型解析在线"
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastModelFeedback = "模型解析失败，已保留本地解析：\(error.localizedDescription)"
                    self.statusText = "模型解析中断"
                }
            }
        }
    }

    /// 对话发生时按需刷新场景理解：被动节流（8 秒抽帧）的结果可能已经陈旧，
    /// 用户开口的瞬间值得拿最新一帧问一次云视觉——"台下有很多人"这类情境
    /// 必须是当下的。尊重路由选择：本地解析模式绝不出网。
    func refreshSceneUnderstandingIfStale(maxAge: TimeInterval = 20, now: Date = Date()) {
        guard Self.shouldRefreshScene(
            routeIsRemote: activeRoute.mode != .local && activeProvider() != nil,
            frameAge: latestFrameForOnDemand.map { now.timeIntervalSince($0.timestamp) },
            understandingAge: now.timeIntervalSince(lastSceneUnderstandingAt),
            maxAge: maxAge
        ), let provider = activeProvider(), let frame = latestFrameForOnDemand else { return }

        lastSceneUnderstandingAt = now
        let envelope = LingShuPerceptionEnvelope(
            timestamp: frame.timestamp,
            kind: .videoFrame,
            source: "mac.camera.on-demand",
            textPayload: nil,
            binaryPayload: frame.jpegData,
            metadata: [
                "encoding": "jpeg",
                "width": String(frame.width),
                "height": String(frame.height),
                "trigger": "conversation"
            ]
        )
        Task {
            do {
                if let reply = try await provider.analyze(envelope) {
                    await MainActor.run {
                        self.latestModelReply = reply
                        self.lastModelFeedback = reply.summary
                        self.refreshSnapshot()
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastModelFeedback = "按需场景理解失败，已保留上一份态势：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 按需刷新的纯判定（可离线测试）：路由是远端 + 有新鲜帧（≤6s）+ 现有理解已陈旧。
    nonisolated static func shouldRefreshScene(routeIsRemote: Bool, frameAge: TimeInterval?, understandingAge: TimeInterval, maxAge: TimeInterval) -> Bool {
        guard routeIsRemote, let frameAge, frameAge <= 6 else { return false }
        return understandingAge >= maxAge
    }

    private func shouldForwardRawSignal(_ kind: LingShuPerceptionSignalKind) -> Bool {
        guard activeRoute.mode != .local, let provider = activeProvider() else { return false }

        let interval = provider.minimumForwardInterval(for: kind)
        let now = Date()
        if interval > 0,
           let lastForwardAt = lastRawForwardAt[kind],
           now.timeIntervalSince(lastForwardAt) < interval {
            return false
        }

        lastRawForwardAt[kind] = now
        return true
    }

    private func recordLocal(kind: LingShuPerceptionSignalKind, summary: String) {
        eventCount += 1
        lastEventSummary = summary
        if activeRoute.mode == .local {
            statusText = "本地解析 \(eventCount)"
        }
    }

    private func refreshSnapshot() {
        latestSnapshot = perceptionThreadCoordinator.makeSnapshot(
            transcription: latestTranscription,
            vision: latestVisionObservation,
            modelReply: latestModelReply
        )
    }
}
