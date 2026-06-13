import XCTest
@testable import LingShuMac

/// 原生多模态兼容:supportsNativeMultimodal 的模型,图片内联进 OpenAI 多模态 content 数组。
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
}
