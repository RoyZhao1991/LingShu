import XCTest
@testable import LingShuMac

/// 流式增量协议层解析器测试:按协议正确解析 + **纯换行块不丢**(之前 markdown 塌成一段的回归点)。
final class StreamChunkParserTests: XCTestCase {

    private let chat = LingShuOpenAIChatStreamChunkParser()

    // MARK: - OpenAI chat/completions(DeepSeek/MiniMax/…)

    func testChatContentDelta() {
        let chunk = chat.parse(line: #"data: {"choices":[{"delta":{"content":"你好"}}]}"#)
        XCTAssertEqual(chunk?.contentDelta, "你好")
    }

    /// 核心回归:纯换行的增量块**必须保留**(DeepSeek 流式换行常是单独一块,丢了 markdown 列表/段落就塌)。
    func testChatPreservesNewlineOnlyChunk() {
        let chunk = chat.parse(line: #"data: {"choices":[{"delta":{"content":"\n"}}]}"#)
        XCTAssertEqual(chunk?.contentDelta, "\n", "纯换行块不能被丢")
    }

    func testChatReasoningContentSeparated() {
        let chunk = chat.parse(line: #"data: {"choices":[{"delta":{"reasoning_content":"先想一下"}}]}"#)
        XCTAssertEqual(chunk?.reasoningDelta, "先想一下")
        XCTAssertEqual(chunk?.contentDelta, "", "reasoning 不进正文")
    }

    func testChatToolCallDelta() {
        let chunk = chat.parse(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_time","arguments":"{\"a\":"}}]}}]}"#)
        let tc = chunk?.toolCallDeltas.first
        XCTAssertEqual(tc?.index, 0)
        XCTAssertEqual(tc?.id, "call_1")
        XCTAssertEqual(tc?.name, "get_time")
        XCTAssertEqual(tc?.argumentsFragment, "{\"a\":")
    }

    func testChatUsageAndDone() {
        let usageChunk = chat.parse(line: #"data: {"choices":[],"usage":{"prompt_tokens":100,"prompt_cache_hit_tokens":80,"total_tokens":120}}"#)
        XCTAssertEqual(usageChunk?.usage?["total_tokens"] as? Int, 120)
        let done = chat.parse(line: "data: [DONE]")
        XCTAssertEqual(done?.done, true)
    }

    func testChatSkipsBlankAndKeepalive() {
        XCTAssertNil(chat.parse(line: ""))
        XCTAssertNil(chat.parse(line: ": keepalive"))
        XCTAssertNil(chat.parse(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), "只有 role、无内容 → 跳过")
    }

    // MARK: - 其它协议

    func testResponsesTextDelta() {
        let parser = LingShuResponsesStreamChunkParser()
        let chunk = parser.parse(line: #"data: {"type":"response.output_text.delta","delta":"片段"}"#)
        XCTAssertEqual(chunk?.contentDelta, "片段")
    }

    func testAnthropicTextDelta() {
        let parser = LingShuAnthropicStreamChunkParser()
        let chunk = parser.parse(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"嗨"}}"#)
        XCTAssertEqual(chunk?.contentDelta, "嗨")
        XCTAssertEqual(parser.parse(line: #"data: {"type":"message_stop"}"#)?.done, true)
    }

    // MARK: - 工厂(按 format 选对解析器)

    func testFactoryRoutesByFormat() {
        XCTAssertTrue(LingShuStreamChunkParsers.parser(for: .chatCompletions) is LingShuOpenAIChatStreamChunkParser)
        XCTAssertTrue(LingShuStreamChunkParsers.parser(for: .responses) is LingShuResponsesStreamChunkParser)
        XCTAssertTrue(LingShuStreamChunkParsers.parser(for: .anthropicMessages) is LingShuAnthropicStreamChunkParser)
    }
}
