import XCTest
@testable import LingShuMac

final class ReplyAdapterStreamTests: XCTestCase {
    private func collect(_ chunks: [String], parser: LingShuReplyStreamParsing) -> (reasoning: String, content: String) {
        var reasoning = ""
        var content = ""
        for chunk in chunks {
            let event = parser.ingest(chunk)
            reasoning += event.reasoningDelta
            content += event.contentDelta
        }
        let tail = parser.finish()
        reasoning += tail.reasoningDelta
        content += tail.contentDelta
        return (reasoning, content)
    }

    func testInlineThinkParserSplitsTagAcrossChunks() {
        let parser = LingShuInlineThinkStreamParser()
        let result = collect(["<th", "ink>先推", "理</thi", "nk>正式回答"], parser: parser)
        XCTAssertEqual(result.reasoning, "先推理")
        XCTAssertEqual(result.content, "正式回答")
    }

    func testInlineThinkParserHandlesMultipleThinkBlocks() {
        let parser = LingShuInlineThinkStreamParser()
        let result = collect(["A<think>一</think>B<think>二</think>C"], parser: parser)
        XCTAssertEqual(result.reasoning, "一二")
        XCTAssertEqual(result.content, "ABC")
    }

    func testInlineThinkParserPassesPlainTextThrough() {
        let parser = LingShuInlineThinkStreamParser()
        let result = collect(["没有标签", "的普通流"], parser: parser)
        XCTAssertEqual(result.reasoning, "")
        XCTAssertEqual(result.content, "没有标签的普通流")
    }

    func testInlineThinkParserDropsDanglingPartialTagAtFinish() {
        let parser = LingShuInlineThinkStreamParser()
        let result = collect(["正文<thi"], parser: parser)
        XCTAssertEqual(result.content, "正文", "残缺标签前缀不是用户内容，不应吐出")
        XCTAssertEqual(result.reasoning, "")
    }

    func testInlineThinkParserIsCaseInsensitive() {
        let parser = LingShuInlineThinkStreamParser()
        let result = collect(["<THINK>推理</Think>回答"], parser: parser)
        XCTAssertEqual(result.reasoning, "推理")
        XCTAssertEqual(result.content, "回答")
    }

    func testUnclosedThinkRoutesTailToReasoning() {
        let parser = LingShuInlineThinkStreamParser()
        let result = collect(["<think>只有推理没有闭合"], parser: parser)
        XCTAssertEqual(result.reasoning, "只有推理没有闭合")
        XCTAssertEqual(result.content, "")
    }

    func testPassthroughParserTreatsEverythingAsContent() {
        let parser = LingShuPassthroughStreamParser()
        let result = collect(["<think>这类模型没有思考标签语义</think>"], parser: parser)
        XCTAssertEqual(result.content, "<think>这类模型没有思考标签语义</think>")
        XCTAssertEqual(result.reasoning, "")
    }

    func testAdapterSelectionByModelFamily() {
        XCTAssertTrue(LingShuModelReplyAdapters.adapter(provider: "MiniMax 官方", model: "MiniMax-M3") is LingShuInlineThinkReplyAdapter)
        XCTAssertTrue(LingShuModelReplyAdapters.adapter(provider: "数据网络", model: "qwen-max") is LingShuInlineThinkReplyAdapter)
        XCTAssertTrue(LingShuModelReplyAdapters.adapter(provider: "OpenAI", model: "gpt-4o") is LingShuPlainReplyAdapter)
        XCTAssertTrue(LingShuModelReplyAdapters.adapter(provider: "Anthropic", model: "claude-sonnet-4-6") is LingShuPlainReplyAdapter)
    }

    func testInlineAdapterNormalizesFinalText() {
        let adapter = LingShuInlineThinkReplyAdapter()
        XCTAssertEqual(adapter.normalizedReplyText("<think>推理</think>最终答案"), "最终答案")
    }

    func testRoutePayloadDecodesChoices() throws {
        let json = """
        {
          "needsAgents": false,
          "agents": [],
          "finalAnswer": "你想要哪种风格？",
          "choices": {
            "question": "选择演示文稿风格",
            "options": [
              { "label": "商务简洁", "detail": "深色底，重点数据放大" },
              { "label": "活泼图形", "detail": "插画风，多图表" },
              { "label": "" }
            ]
          }
        }
        """
        let payload = try JSONDecoder().decode(LingShuRoutePayload.self, from: Data(json.utf8))
        let choices = try XCTUnwrap(payload.choices)
        XCTAssertEqual(choices.question, "选择演示文稿风格")
        XCTAssertEqual(choices.options.map(\.label), ["商务简洁", "活泼图形"], "空标签选项应被过滤")
    }

    func testChoicePromptWithSingleOptionIsRejected() throws {
        let json = """
        {
          "needsAgents": false,
          "agents": [],
          "finalAnswer": "好的",
          "choices": { "question": "只有一个选项", "options": [ { "label": "唯一" } ] }
        }
        """
        let payload = try JSONDecoder().decode(LingShuRoutePayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.choices, "少于 2 个有效选项不构成选择卡片")
    }
}
