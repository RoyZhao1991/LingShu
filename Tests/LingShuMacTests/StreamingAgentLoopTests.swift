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

    func testPlainTextStreamStillPassesThrough() {
        var filter = LingShuStructuredStreamVisibilityFilter()

        XCTAssertEqual(filter.consume("你好"), "你好")
        XCTAssertEqual(filter.consume("，灵枢在。"), "，灵枢在。")
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
    func testStateStreamingBubbleStillShowsPlainTextDeltas() {
        let state = LingShuState()
        let bubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [bubble]

        state.appendStreamingBubbleText("你好", to: bubble.id)
        state.appendStreamingBubbleText("，我在。", to: bubble.id)
        state.flushStreamingBubbleText(for: bubble.id)

        XCTAssertEqual(state.chatMessages.first?.text, "你好，我在。")
    }

    @MainActor
    func testShortStreamingDeltaIsBufferedUntilFlush() {
        let state = LingShuState()
        let bubble = ChatMessage(speaker: "灵枢", text: "", isUser: false, isLoading: true)
        state.chatMessages = [bubble]

        state.appendStreamingBubbleText("短句未完", to: bubble.id)
        XCTAssertEqual(state.chatMessages.first?.text, "", "短小未收口 delta 不应每 token 刷新 UI")
        XCTAssertEqual(state.streamingBubblePendingDeltas[bubble.id], "短句未完")

        state.flushStreamingBubbleText(for: bubble.id)
        XCTAssertEqual(state.chatMessages.first?.text, "短句未完")
        XCTAssertNil(state.streamingBubblePendingDeltas[bubble.id])
    }
}
