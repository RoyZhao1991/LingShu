import XCTest
@testable import LingShuMac

/// 复现并锁死"思考链泄漏到正文"那个 bug：模型用 `<mm:think>` 等变体时，
/// 旧逻辑只认 `<think>`，把整段英文思考(含 `</mm:think>`)甩给了用户。
final class MMThinkTagTests: XCTestCase {
    func testStripsMMThinkPairedBlock() {
        let raw = "<mm:think>I need to determine if this is a continuation...</mm:think>收到。后台正在执行。"
        XCTAssertEqual(LingShuReasoningText.stripThinkTags(raw), "收到。后台正在执行。")
    }

    func testStripsOrphanCloseTag_screenshotCase() {
        // 截图里的形态：开标签缺失/被吞，思考链 + </mm:think> + 真正回答。
        let raw = "I need to determine if this is a continuation of a prior PPT task...\nLet me route this properly.</mm:think>收到。这件事需要能力节点协作，我已分派给 规划、审议、调度。"
        XCTAssertEqual(
            LingShuReasoningText.stripThinkTags(raw),
            "收到。这件事需要能力节点协作，我已分派给 规划、审议、调度。"
        )
    }

    func testStripsThinkingVariantAndBareTags() {
        XCTAssertEqual(LingShuReasoningText.stripThinkTags("<thinking>x</thinking>答案"), "答案")
        XCTAssertEqual(LingShuReasoningText.stripThinkTags("答案</think>"), "答案")
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(LingShuReasoningText.stripThinkTags("就是普通回答，没有标签。"), "就是普通回答，没有标签。")
    }

    func testStreamParserRoutesMMThinkToReasoningNotContent() {
        let parser = LingShuInlineThinkStreamParser()
        var reasoning = ""
        var content = ""
        for chunk in ["<mm:th", "ink>英文思考", "</mm:thi", "nk>收到，已分派。"] {
            let event = parser.ingest(chunk)
            reasoning += event.reasoningDelta
            content += event.contentDelta
        }
        let tail = parser.finish()
        reasoning += tail.reasoningDelta
        content += tail.contentDelta
        XCTAssertEqual(reasoning, "英文思考")
        XCTAssertEqual(content, "收到，已分派。")
    }
}
