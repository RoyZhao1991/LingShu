import XCTest
@testable import LingShuMac

/// 前缀缓存按厂商适配的测试:策略选择 + Anthropic 显式 cache_control 注入 + 跨厂商 usage 解析。
final class LingShuPrefixCacheTests: XCTestCase {

    // MARK: - 策略选择(换模型自动选对)

    func testStrategyPerFormat() {
        XCTAssertEqual(LingShuPrefixCache.strategy(for: .chatCompletions), .automatic)
        XCTAssertEqual(LingShuPrefixCache.strategy(for: .responses), .automatic)
        XCTAssertEqual(LingShuPrefixCache.strategy(for: .anthropicMessages), .anthropicExplicit)
        XCTAssertEqual(LingShuPrefixCache.strategy(for: .codexBridge), .unsupported)
        XCTAssertEqual(LingShuPrefixCache.strategy(for: .hostAdapter), .unsupported)
    }

    func testAnthropicProviderResolvesToExplicitStrategy() {
        let gateway = LingShuModelGateway()
        let format = gateway.requestFormat(provider: "Anthropic Claude", endpoint: "https://api.anthropic.com/v1", protocolName: "Anthropic")
        XCTAssertEqual(format, .anthropicMessages)
        XCTAssertEqual(LingShuPrefixCache.strategy(for: format), .anthropicExplicit)
    }

    func testDeepSeekProviderResolvesToAutomaticStrategy() {
        let gateway = LingShuModelGateway()
        let format = gateway.requestFormat(provider: "DeepSeek", endpoint: "https://api.deepseek.com/v1", protocolName: "OpenAI Chat")
        XCTAssertEqual(format, .chatCompletions)
        XCTAssertEqual(LingShuPrefixCache.strategy(for: format), .automatic)
    }

    // MARK: - Anthropic 请求体注入 cache_control(否则 Claude 完全不缓存)

    func testAnthropicBodyPutsCacheControlOnSystemAndLastMessage() throws {
        let body = try LingShuModelGateway.anthropicMessagesBody(
            model: "claude-sonnet-4.5",
            systemPrompt: "你是灵枢。",
            messages: [
                .init(role: "user", content: "第一句"),
                .init(role: "assistant", content: "回应"),
                .init(role: "user", content: "最后一句")
            ],
            temperature: 0.2,
            stream: false,
            cache: .anthropicExplicit
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        // system → 带 cache_control 的 content block 数组。
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["type"] as? String, "text")
        XCTAssertNotNil(system.first?["cache_control"])

        // 只有最后一条消息打断点(缓存到上一轮为止的整段前缀);前面的保持纯字符串。
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages[0]["content"] is String)
        let lastContent = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertNotNil(lastContent.first?["cache_control"])
    }

    func testAnthropicBodyWithoutExplicitStrategyHasNoCacheControl() throws {
        let body = try LingShuModelGateway.anthropicMessagesBody(
            model: "claude-sonnet-4.5",
            systemPrompt: "你是灵枢。",
            messages: [.init(role: "user", content: "你好")],
            temperature: 0.2,
            stream: false,
            cache: .automatic
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("cache_control"))
        XCTAssertTrue(raw.contains("\"system\":\"你是灵枢。\"") || raw.contains("你是灵枢"))
    }

    // MARK: - 跨厂商 usage 解析(可观测命中量)

    func testParseCacheUsageOpenAIStyle() {
        let usage: [String: Any] = ["prompt_tokens": 1000, "prompt_tokens_details": ["cached_tokens": 800]]
        let r = LingShuPrefixCache.parseCacheUsage(usage)
        XCTAssertEqual(r.promptTokens, 1000)
        XCTAssertEqual(r.cachedTokens, 800)
    }

    func testParseCacheUsageDeepSeekStyle() {
        let usage: [String: Any] = ["prompt_tokens": 1200, "prompt_cache_hit_tokens": 1024]
        let r = LingShuPrefixCache.parseCacheUsage(usage)
        XCTAssertEqual(r.cachedTokens, 1024)
    }

    func testParseCacheUsageAnthropicStyle() {
        let usage: [String: Any] = ["input_tokens": 50, "cache_read_input_tokens": 4096]
        let r = LingShuPrefixCache.parseCacheUsage(usage)
        XCTAssertEqual(r.promptTokens, 50)
        XCTAssertEqual(r.cachedTokens, 4096)
    }
}
