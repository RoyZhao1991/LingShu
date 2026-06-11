import XCTest
@testable import LingShuMac

final class CloudPerceptionRouteTests: XCTestCase {
    private func makeClient() -> LingShuCloudPerceptionClient {
        LingShuCloudPerceptionClient(
            baseEndpoint: URL(string: "https://model-gateway.datanet.bj.cn/v1")!,
            token: "sk-test-token"
        )
    }

    // MARK: - WAV 封装

    func testWAVEncoderProducesValidRIFFHeader() {
        let pcm = Data(repeating: 0x01, count: 3200)
        let wav = LingShuWAVEncoder.encode(pcm16: pcm, sampleRate: 16000, channels: 1)

        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")

        let sampleRate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        XCTAssertEqual(sampleRate, 16000)
        let dataSize = wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        XCTAssertEqual(dataSize, UInt32(pcm.count))
    }

    // MARK: - 音频拼批

    func testAudioBufferAccumulatesUntilBatchThreshold() {
        let provider = LingShuDataNetPerceptionProvider(
            client: makeClient(),
            audioBatchSeconds: 1,
            audioMinInterval: 0
        )
        // 16kHz 单声道 PCM16：每秒 32000 字节；先喂 0.5 秒 → 继续缓冲
        let halfSecond = Data(repeating: 0, count: 16000)
        XCTAssertNil(provider.bufferAndDrainAudio(pcm: halfSecond, sampleRate: 16000, channels: 1))

        // 再喂 0.6 秒 → 凑满 1 秒批，出 WAV
        let moreAudio = Data(repeating: 0, count: 19200)
        let wav = provider.bufferAndDrainAudio(pcm: moreAudio, sampleRate: 16000, channels: 1)
        XCTAssertNotNil(wav)
        XCTAssertEqual(wav?.count, 44 + 16000 + 19200)
    }

    func testAudioBufferRespectsMinimumUploadInterval() {
        let provider = LingShuDataNetPerceptionProvider(
            client: makeClient(),
            audioBatchSeconds: 1,
            audioMinInterval: 10
        )
        let oneSecond = Data(repeating: 0, count: 32000)
        let now = Date()
        XCTAssertNotNil(provider.bufferAndDrainAudio(pcm: oneSecond, sampleRate: 16000, channels: 1, now: now))
        // 间隔不足 10 秒：继续缓冲
        XCTAssertNil(provider.bufferAndDrainAudio(pcm: oneSecond, sampleRate: 16000, channels: 1, now: now.addingTimeInterval(3)))
        // 超过 10 秒：出批
        XCTAssertNotNil(provider.bufferAndDrainAudio(pcm: oneSecond, sampleRate: 16000, channels: 1, now: now.addingTimeInterval(11)))
    }

    // MARK: - 结果映射

    func testReplyMappingSummarizesVisionResult() {
        let reply = LingShuDataNetPerceptionProvider.makeReply(from: .init(
            success: true,
            taskType: "image",
            transcript: "",
            ocrTexts: ["会议室预定表", "14:00 评审"],
            detectionCount: 2,
            semanticSuggestions: "",
            warnings: [],
            totalTokens: 688,
            model: "swds-vision-fast"
        ))
        XCTAssertTrue(reply.summary.contains("画面文字：会议室预定表、14:00 评审"))
        XCTAssertTrue(reply.summary.contains("检出对象 2 个"))
        XCTAssertEqual(reply.metadata?["totalTokens"], "688")
        XCTAssertNil(reply.transcript)
    }

    func testReplyMappingCarriesAudioTranscript() {
        let reply = LingShuDataNetPerceptionProvider.makeReply(from: .init(
            success: true,
            taskType: "audio",
            transcript: "灵枢网关连通测试。",
            ocrTexts: [],
            detectionCount: 0,
            semanticSuggestions: "",
            warnings: [],
            totalTokens: 2817,
            model: "swds-realtime-hearing"
        ))
        XCTAssertEqual(reply.transcript, "灵枢网关连通测试。")
        XCTAssertTrue(reply.summary.contains("听觉转写"))
    }

    // MARK: - 网关路由注册

    @MainActor
    func testGatewayRegistersAndAutoSelectsCloudRoute() {
        let gateway = LingShuRealtimePerceptionGateway()
        XCTAssertEqual(gateway.activeRoute.id, LingShuPerceptionRoute.local.id)

        gateway.registerCloudPerceptionRoute(client: makeClient())
        XCTAssertTrue(gateway.availableRoutes.contains(where: { $0.id == LingShuDataNetPerceptionProvider.routeID }))
        XCTAssertEqual(gateway.activeRoute.id, LingShuDataNetPerceptionProvider.routeID)

        gateway.registerCloudPerceptionRoute(client: nil)
        XCTAssertFalse(gateway.availableRoutes.contains(where: { $0.id == LingShuDataNetPerceptionProvider.routeID }))
        XCTAssertEqual(gateway.activeRoute.id, LingShuPerceptionRoute.local.id)
    }

    @MainActor
    func testGatewayKeepsUserSelectedRouteWhenCloudReregisters() {
        let gateway = LingShuRealtimePerceptionGateway()
        gateway.configureRemoteEndpoints([
            .init(
                id: "custom-endpoint",
                displayName: "自建感知",
                endpoint: URL(string: "https://example.com/perception")!,
                apiKey: "k",
                protocolName: "realtime",
                supportedSignals: [.videoFrame]
            )
        ])
        gateway.selectRoute(id: "custom-endpoint")

        gateway.registerCloudPerceptionRoute(client: makeClient())
        XCTAssertEqual(gateway.activeRoute.id, "custom-endpoint", "云路由注册不应抢占用户手动选择的路由")
        XCTAssertTrue(gateway.availableRoutes.contains(where: { $0.id == LingShuDataNetPerceptionProvider.routeID }))
    }
}
