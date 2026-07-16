import XCTest
@testable import LingShuMac

/// 数据增值协作网络算力中心网关的适配测试。
/// fixture 均来自 2026-06-11 对真实网关的最小调用响应（已脱敏截取）。
final class CloudGatewayTests: XCTestCase {

    // MARK: - 预设与请求契约

    func testDataNetGatewayPresetRoutesEverythingThroughGatewayDomain() {
        let preset = ModelProviderPreset.dataNetGateway
        XCTAssertEqual(preset.endpoint, "https://model-gateway.datanet.bj.cn/v1")
        XCTAssertEqual(preset.defaultModels.first, "swds-multimodal-parse")
        XCTAssertTrue(preset.defaultModels.contains("swds-text-parse"))
        XCTAssertTrue(ModelProviderPreset.catalog.contains(where: { $0.id == preset.id }))
    }

    func testGatewayContractUsesChatCompletionsWithModelTokenHeader() throws {
        let gateway = LingShuModelGateway()
        let contract = try gateway.makeInvocationContract(
            provider: "数据网络网关",
            model: "swds-multimodal-parse",
            endpoint: "https://model-gateway.datanet.bj.cn/v1",
            protocolName: "OpenAI Chat",
            apiKey: "sk-test-token",
            systemPrompt: "你是灵枢。",
            userPrompt: "连通性测试",
            temperature: 0.2,
            stream: false
        )

        XCTAssertEqual(contract.format, .chatCompletions)
        XCTAssertEqual(contract.url.absoluteString, "https://model-gateway.datanet.bj.cn/v1/chat/completions")
        XCTAssertEqual(contract.headers["X-Model-Token"], "sk-test-token")
        XCTAssertNil(contract.headers["Authorization"], "数据网络网关使用 X-Model-Token，不应同时下发 Bearer 头")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "swds-multimodal-parse")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
    }

    // MARK: - Chat 响应解析

    private static let chatFixture = """
    {"id":"chatcmpl-1","object":"chat.completion","created":1781171822,"model":"minimax-m2.7",
     "choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant",
     "content":"你好，连通性测试成功！",
     "reasoning_content":"用户要求做一次连通性测试，回复一句话即可。"}}],
     "usage":{"prompt_tokens":13343,"completion_tokens":47,"total_tokens":13390}}
    """

    func testChatResponseExtractsContentWithoutMixingReasoning() throws {
        let gateway = LingShuModelGateway()
        let text = try gateway.decodeTextResponse(
            data: Data(Self.chatFixture.utf8),
            statusCode: 200
        )
        XCTAssertEqual(text, "你好，连通性测试成功！")
        XCTAssertFalse(text.contains("连通性测试，回复一句话"), "reasoning_content 不得混入正文")
    }

    func testChatResponseRecordsGatewayTokenUsage() {
        XCTAssertEqual(
            LingShuRemoteModelClient.decodeTotalTokens(data: Data(Self.chatFixture.utf8)),
            13390
        )
    }

    // MARK: - 感知接口解析

    func testImagePerceptionDecodesOCRAndUsage() throws {
        let fixture = """
        {"success":true,"task_type":"image","image":{"width":200,"height":80},
         "ocr":{"blocks":[{"text":"LingShu Test 2026","score":0.998,"bbox":[8.0,27.0,100.0,46.0]}],"count":1},
         "detections":[],"semantic_suggestions":{},
         "warnings":[],"usage":{"prompt_tokens":568,"completion_tokens":120,"total_tokens":688},
         "model":"swds-vision-fast"}
        """
        let result = try LingShuCloudPerceptionClient.decodeResult(from: Data(fixture.utf8))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.taskType, "image")
        XCTAssertEqual(result.ocrTexts, ["LingShu Test 2026"])
        XCTAssertEqual(result.detectionCount, 0)
        XCTAssertEqual(result.totalTokens, 688)
        XCTAssertEqual(result.model, "swds-vision-fast")
    }

    func testAudioPerceptionDecodesTranscript() throws {
        let fixture = """
        {"success":true,"task_type":"audio",
         "transcript":{"text":"灵书网关联通测试。","segments":[]},
         "semantic_suggestions":{},"warnings":[],
         "usage":{"prompt_tokens":2733,"completion_tokens":84,"total_tokens":2817},
         "model":"swds-realtime-hearing"}
        """
        let result = try LingShuCloudPerceptionClient.decodeResult(from: Data(fixture.utf8))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.taskType, "audio")
        XCTAssertEqual(result.transcript, "灵书网关联通测试。")
        XCTAssertEqual(result.totalTokens, 2817)
    }

    func testVideoPerceptionDecodesKeyframesAndWarnings() throws {
        let fixture = """
        {"success":true,"task_type":"video",
         "video":{"fps":4.0,"frame_count":8,"duration_sec":2.0},
         "keyframes":[{"timestamp_sec":0.5,"ocr":[{"text":"00:01"}],"detections":[]},
                      {"timestamp_sec":1.5,"ocr":[],"detections":[]}],
         "transcript":{"text":"","segments":[]},
         "semantic_suggestions":{},
         "warnings":["video_audio_not_found_or_ffmpeg_failed"],
         "usage":{"prompt_tokens":2551,"completion_tokens":192,"total_tokens":2743},
         "model":"swds-vision-deep"}
        """
        let result = try LingShuCloudPerceptionClient.decodeResult(from: Data(fixture.utf8))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.taskType, "video")
        XCTAssertEqual(result.ocrTexts, ["00:01"])
        XCTAssertEqual(result.warnings, ["video_audio_not_found_or_ffmpeg_failed"])
        XCTAssertEqual(result.totalTokens, 2743)
    }

    func testPerceptionRequestsRequireMediaSource() async {
        let client = LingShuCloudPerceptionClient(
            baseEndpoint: URL(string: "https://model-gateway.datanet.bj.cn/v1")!,
            token: "sk-test-token"
        )
        do {
            _ = try await client.analyzeImage()
            XCTFail("缺少媒体来源时应当抛错，而不是发起空请求")
        } catch let error as LingShuCloudPerceptionError {
            XCTAssertEqual(error, .missingMediaSource)
        } catch {
            XCTFail("应抛出 missingMediaSource，实际为 \(error)")
        }
    }

    // MARK: - 凭据仓库

    func testCredentialStoreRoundTripsThroughKeychain() {
        let service = "cn.lingshu.tests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-keychain-test-\(UUID().uuidString)", isDirectory: true)
        let store = LingShuCredentialStore(service: service, directory: directory, useKeychain: true)
        let provider = "unit-test-provider"

        XCTAssertNil(store.apiKey(forProvider: provider))
        XCTAssertTrue(store.setAPIKey("sk-unit-test-key", forProvider: provider))
        XCTAssertEqual(store.apiKey(forProvider: provider), "sk-unit-test-key")

        let reopened = LingShuCredentialStore(service: service, directory: directory, useKeychain: true)
        XCTAssertEqual(reopened.apiKey(forProvider: provider), "sk-unit-test-key")

        XCTAssertTrue(reopened.setAPIKey("", forProvider: provider))
        let afterDeletion = LingShuCredentialStore(service: service, directory: directory, useKeychain: true)
        XCTAssertNil(afterDeletion.apiKey(forProvider: provider))
    }

    func testCredentialStoreMigratesLegacyEncryptedFileIntoKeychain() {
        let service = "cn.lingshu.tests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-keychain-migration-\(UUID().uuidString)", isDirectory: true)
        let provider = "legacy-provider"
        let legacy = LingShuCredentialStore(service: service, directory: directory, useKeychain: false)
        XCTAssertTrue(legacy.setAPIKey("legacy-test-key", forProvider: provider))

        let migrated = LingShuCredentialStore(service: service, directory: directory, useKeychain: true)
        XCTAssertEqual(migrated.apiKey(forProvider: provider), "legacy-test-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("credentials.json").path))

        XCTAssertTrue(migrated.setAPIKey("", forProvider: provider))
    }

    func testCredentialStoreEnvironmentKeyNaming() {
        XCTAssertEqual(
            LingShuCredentialStore.environmentKey(forProvider: "datanet-gateway"),
            "LINGSHU_TOKEN_DATANET_GATEWAY"
        )
    }
}
