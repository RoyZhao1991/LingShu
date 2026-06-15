import XCTest
@testable import LingShuMac

final class MinimaxChannelTests: XCTestCase {
    func testStripThinkTagsRemovesInlineReasoning() {
        let text = "<think>\n用户要打招呼，我应该回复。\n</think>你好，我是灵枢。"
        XCTAssertEqual(LingShuReasoningText.stripThinkTags(text), "你好，我是灵枢。")
    }

    func testStripThinkTagsHandlesDanglingTags() {
        XCTAssertEqual(LingShuReasoningText.stripThinkTags("<think>只剩开标签的正文"), "只剩开标签的正文")
        XCTAssertEqual(LingShuReasoningText.stripThinkTags("正文 </think>"), "正文")
    }

    func testMinimaxOfficialIsDefaultPureInferenceChannel() {
        let preset = ModelProviderPreset.minimaxOfficial
        XCTAssertEqual(preset.endpoint, "https://api.minimaxi.com/v1")
        XCTAssertEqual(preset.defaultModels.first, "MiniMax-M3")
        XCTAssertEqual(ModelProviderPreset.apiCatalog.first?.id, preset.id, "MiniMax 官方应排在 API 通道目录首位")
    }

    @MainActor
    func testDefaultMainChannelIsMinimaxOfficial() {
        let state = LingShuState()
        XCTAssertEqual(state.modelProvider, ModelProviderPreset.minimaxOfficial.name)
        XCTAssertEqual(state.modelName, "MiniMax-M3")
        XCTAssertTrue(state.shouldUseLocalStreamingDialogue, "MiniMax 官方应启用标准流式")
    }
}
