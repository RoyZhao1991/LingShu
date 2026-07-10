import XCTest
@testable import LingShuMac

/// 原生多模态兼容:OpenAI/GPT 兼容通道默认先尝试 image_url,失败后再按模型记忆降级。
final class NativeMultimodalTests: XCTestCase {
    private let gateway = LingShuModelGateway()

    func testInlineImageEncodedAsMultimodalContent() throws {
        let dataURL = "data:image/png;base64,AAAA"
        let contract = try gateway.makeInvocationContract(
            provider: "KIMI", model: "kimi-k2.6", endpoint: "https://api.moonshot.cn/v1",
            protocolName: "OpenAI 兼容", apiKey: "sk-x",
            systemPrompt: "你是灵枢。", userPrompt: "",
            temperature: 0.6, stream: false,
            conversationMessages: [
                .init(role: "system", content: "你是灵枢。"),
                .init(role: "user", content: "这张图是什么？", imageDataURLs: [dataURL])
            ]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
        XCTAssertNil(object["tools"], "无工具的多模态请求不该带 tools 键")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let userMsg = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
        let content = try XCTUnwrap(userMsg["content"] as? [[String: Any]], "图片消息 content 应是多模态数组")
        XCTAssertTrue(content.contains { $0["type"] as? String == "text" })
        let image = try XCTUnwrap(content.first { $0["type"] as? String == "image_url" })
        XCTAssertEqual((image["image_url"] as? [String: Any])?["url"] as? String, dataURL)
    }

    func testNoImageStaysPlainStringContent() throws {
        let contract = try gateway.makeInvocationContract(
            provider: "MiniMax", model: "M3", endpoint: "https://api.minimax.chat/v1",
            protocolName: "OpenAI 兼容", apiKey: "sk-x",
            systemPrompt: "你是灵枢。", userPrompt: "你好",
            temperature: 0.6, stream: false
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        // 无图片 → content 仍是普通字符串(走既有 Codable 路径,零回归)。
        XCTAssertTrue(messages.allSatisfy { $0["content"] is String })
    }

    func testOpenAICompatibleModelAttemptsNativeMultimodalByDefaultThenCanBeMarkedUnsupported() {
        let suiteName = "NativeMultimodalTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let provider = "MiniMax 官方"
        let model = "MiniMax-M3"
        let endpoint = "https://api.minimaxi.com/v1"
        let proto = "OpenAI Chat"

        XCTAssertTrue(LingShuMultimodal.shouldAttemptNativeMultimodal(
            provider: provider, model: model, endpoint: endpoint, protocolName: proto, defaults: suite
        ), "GPT/OpenAI 兼容通道默认先尝试原生多模态,不再靠模型名白名单")

        LingShuMultimodal.markNativeMultimodalUnsupported(
            provider: provider, model: model, endpoint: endpoint, protocolName: proto, defaults: suite
        )

        XCTAssertFalse(LingShuMultimodal.shouldAttemptNativeMultimodal(
            provider: provider, model: model, endpoint: endpoint, protocolName: proto, defaults: suite
        ), "确认端点拒绝后,同一模型下次直接走降级策略")
    }

    func testImageURLRejectionClassifiedAsNativeMultimodalUnsupported() {
        let failure = LingShuModelServiceFailure.classify(
            statusCode: 400,
            body: #"{"error":{"message":"unsupported content type image_url for this model"}}"#
        )
        XCTAssertEqual(failure.kind, .multimodalUnsupported)
        XCTAssertTrue(LingShuModelServiceFailure.isNativeMultimodalUnsupportedReason(failure.encodedReason))
    }
}
