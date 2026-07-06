import XCTest
@testable import LingShuMac

/// 真流式接线测试:设了 delta sink 的会话走流式(逐字透传、顺序正确);不设则走非流式 respond(零变更)。
final class StreamingAgentLoopTests: XCTestCase {

    private actor DeltaCollector {
        private(set) var parts: [String] = []
        func add(_ s: String) { parts.append(s) }
        var joined: String { parts.joined() }
    }

    /// 流式模型:逐块回调 onTextDelta,最终返回完整文本。respond 不应被调用(设了 sink 时)。
    private struct MockStreamingModel: LingShuAgentModel {
        let chunks: [String]
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            .text("【不应走到非流式】")
        }
        func respondStreaming(messages: [LingShuAgentMessage], tools: [LingShuAgentTool], onTextDelta: @Sendable (String) async -> Void) async -> LingShuAgentModelResponse {
            for chunk in chunks { await onTextDelta(chunk) }
            return .text(chunks.joined())
        }
    }

    /// 只实现 respond → respondStreaming 用协议默认实现(回退非流式)。
    private struct MockNonStreamingModel: LingShuAgentModel {
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            .text("非流式答复")
        }
    }

    func testSessionStreamsDeltasInOrderWhenSinkSet() async {
        let collector = DeltaCollector()
        let session = LingShuAgentSession(id: "stream-test", tools: [], model: MockStreamingModel(chunks: ["你好", "，", "世界", "!"]))
        await session.setTextDeltaSink { delta in await collector.add(delta) }

        let result = await session.send("hi")

        let streamed = await collector.joined
        XCTAssertEqual(streamed, "你好，世界!", "逐字 delta 应按顺序完整透传")
        guard case .completed(let text) = result else { return XCTFail("应正常收尾") }
        XCTAssertEqual(text, "你好，世界!")
    }

    func testSessionUsesNonStreamingWhenNoSink() async {
        let collector = DeltaCollector()
        // 设了流式模型但**不设 sink** → runLoop 走 respond 分支(此处 MockNonStreamingModel 只有 respond)。
        let session = LingShuAgentSession(id: "nostream-test", tools: [], model: MockNonStreamingModel())

        let result = await session.send("hi")

        let streamed = await collector.joined
        XCTAssertEqual(streamed, "", "没设 sink 不该有任何 delta")
        guard case .completed(let text) = result else { return XCTFail("应正常收尾") }
        XCTAssertEqual(text, "非流式答复")
    }

    func testDefaultRespondStreamingFallsBackToRespond() async {
        // 协议默认 respondStreaming 应回退到 respond(脚本模型/不支持流式的供应商不必各自实现)。
        let model = MockNonStreamingModel()
        let response = await model.respondStreaming(messages: [], tools: []) { _ in }
        guard case .text(let text) = response else { return XCTFail("默认实现应回退 respond 返回 .text") }
        XCTAssertEqual(text, "非流式答复")
    }

    func testStructuredJSONStreamIsHiddenFromVisibleBubble() {
        var filter = LingShuStructuredStreamVisibilityFilter()

        XCTAssertEqual(filter.consume("{"), "")
        XCTAssertEqual(filter.consume("\"reply\":\"你好\""), "")
        XCTAssertEqual(filter.consume(",\"OAuth\":null}"), "")
    }

    func testFencedStructuredJSONStreamIsHiddenFromVisibleBubble() {
        var filter = LingShuStructuredStreamVisibilityFilter()

        XCTAssertEqual(filter.consume("```"), "")
        XCTAssertEqual(filter.consume("json\n{\"reply\":\"你好\"}"), "")
        XCTAssertEqual(filter.consume("\n```"), "")
    }

    func testPlainTextStreamBuffersBrieflyThenPassesThroughWhenNoProtocolAppears() {
        var filter = LingShuStructuredStreamVisibilityFilter()

        XCTAssertEqual(filter.consume("你好"), "", "短的未解析片段先停留在加载态，避免稍后接 JSON 时协议泄漏")
        let longPlain = String(repeating: "这是一段普通自然语言回复。", count: 12)
        let visible = filter.consume(longPlain)
        XCTAssertTrue(visible.contains("你好"))
        XCTAssertTrue(visible.contains("普通自然语言回复"))
        XCTAssertEqual(filter.consume("后续继续透出。"), "后续继续透出。")
    }

    @MainActor
    func testStateStreamingBubbleHidesStructuredJSONDeltas() {
        let state = LingShuState()
        let bubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [bubble]

        state.appendStreamingBubbleText("{\"reply\":\"你好\"", to: bubble.id)
        state.appendStreamingBubbleText(",\"OAuth\":null}", to: bubble.id)

        XCTAssertEqual(state.chatMessages.first?.text, "")
    }

    @MainActor
    func testStateStreamingBubbleStillShowsLongPlainTextDeltas() {
        let state = LingShuState()
        let bubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [bubble]

        let longPlain = String(repeating: "你好，我在。", count: 24)
        state.appendStreamingBubbleText(longPlain, to: bubble.id)
        state.flushStreamingBubbleText(for: bubble.id)

        XCTAssertEqual(state.chatMessages.first?.text, longPlain)
    }

    @MainActor
    func testShortStreamingDeltaIsBufferedUntilFlush() {
        let state = LingShuState()
        let bubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [bubble]

        state.appendStreamingBubbleText("短句未完", to: bubble.id)
        XCTAssertEqual(state.chatMessages.first?.text, "", "短小未解析 delta 不应每 token 刷新 UI")
        XCTAssertNil(state.streamingBubblePendingDeltas[bubble.id])
        XCTAssertEqual(state.chatMessages.first?.thinkingPreview, "正在解析结构化回复，确认最终可见内容…")

        state.flushStreamingBubbleText(for: bubble.id)
        XCTAssertEqual(state.chatMessages.first?.text, "")
        XCTAssertNil(state.streamingBubblePendingDeltas[bubble.id])
    }

    @MainActor
    func testMixedStructuredJSONStreamClearsVisiblePrefixAndHidesProtocol() {
        let state = LingShuState()
        let bubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [bubble]

        let temporaryPlain = String(repeating: "临时说明。", count: 28)
        state.appendStreamingBubbleText(temporaryPlain, to: bubble.id)
        state.flushStreamingBubbleText(for: bubble.id)
        XCTAssertEqual(state.chatMessages.first?.text, temporaryPlain)

        state.appendStreamingBubbleText("\n{\"reply\":\"最终正文\",\"completion\":{\"status\":\"ok\",\"needs_user\":false},\"OAuth\":null}", to: bubble.id)
        state.flushStreamingBubbleText(for: bubble.id)

        XCTAssertEqual(state.chatMessages.first?.text, "", "发现结构化协议后，要清掉此前误露的临时文本")
        XCTAssertEqual(state.chatMessages.first?.thinkingPreview, "正在解析结构化回复，确认最终可见内容…")
    }

    func testMixedStructuredJSONFinalVisibleTextExtractsReplyWithoutDrivingFlow() {
        let mixed = """
        这个问题问的是定义性知识，可以直接回答。
        {"reply":"最终只展示这句话","completion":{"status":"ok","needs_user":false},"user_input":null,"inability":null,"OAuth":null}
        """

        XCTAssertNil(LingShuStructuredModelOutput.parse(mixed), "流程层仍只接受整段完整 JSON，混合文本不能驱动 OAuth/user_input/completion")
        XCTAssertEqual(LingShuStructuredModelOutput.visibleText(from: mixed), "最终只展示这句话")
    }
}
