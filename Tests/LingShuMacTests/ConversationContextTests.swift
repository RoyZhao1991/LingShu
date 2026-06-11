import XCTest
@testable import LingShuMac

final class ConversationContextTests: XCTestCase {
    private func msg(_ text: String, user: Bool) -> ChatMessage {
        ChatMessage(speaker: user ? "你" : "灵枢", text: text, isUser: user)
    }

    private let identity: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    func testWindowKeepsChronologicalAppendOnlyOrder() {
        let messages = [
            msg("第一轮问题", user: true),
            msg("第一轮回答", user: false),
            msg("第二轮问题", user: true),
            msg("第二轮回答", user: false)
        ]
        let window = LingShuState.conversationWindow(
            from: messages,
            budget: 16000,
            excludingTrailingPromptMatching: nil,
            normalize: identity,
            compact: { $0 }
        )
        XCTAssertEqual(window.map(\.content), ["第一轮问题", "第一轮回答", "第二轮问题", "第二轮回答"])
        XCTAssertEqual(window.map(\.role), ["user", "assistant", "user", "assistant"])
    }

    func testWindowDropsOldestWhenOverBudgetButKeepsRecent() {
        let messages = (1...20).map { msg("第\($0)轮消息内容占位填充", user: $0 % 2 == 1) }
        // 每条约 12 字符 + 8，预算 60 只能容纳最后几条
        let window = LingShuState.conversationWindow(
            from: messages,
            budget: 60,
            excludingTrailingPromptMatching: nil,
            normalize: identity,
            compact: { $0 }
        )
        XCTAssertFalse(window.isEmpty)
        XCTAssertTrue(window.count < messages.count, "超预算时应丢弃较早轮次")
        XCTAssertEqual(window.last?.content, "第20轮消息内容占位填充", "必须保留最近一轮")
    }

    func testWindowExcludesDuplicateTrailingUserPrompt() {
        let messages = [
            msg("做个PPT", user: true),
            msg("好的，已生成大纲", user: false),
            msg("再加一页", user: true)
        ]
        // 末条用户消息与本轮 rawPrompt 相同 → 不应重复进历史（本轮会单独作为 finalUserPrompt 追加）
        let window = LingShuState.conversationWindow(
            from: messages,
            budget: 16000,
            excludingTrailingPromptMatching: "再加一页",
            normalize: identity,
            compact: { $0 }
        )
        XCTAssertEqual(window.map(\.content), ["做个PPT", "好的，已生成大纲"])
    }

    func testWindowSkipsLoadingAndEmptyMessages() {
        var loading = msg("", user: false)
        loading.isLoading = true
        let messages = [
            msg("问题", user: true),
            loading,
            msg("   ", user: false),
            msg("回答", user: false)
        ]
        let window = LingShuState.conversationWindow(
            from: messages,
            budget: 16000,
            excludingTrailingPromptMatching: nil,
            normalize: identity,
            compact: { $0 }
        )
        XCTAssertEqual(window.map(\.content), ["问题", "回答"])
    }

    func testCompactTruncatesOnlyVeryLongText() {
        let short = String(repeating: "字", count: 100)
        XCTAssertEqual(LingShuState.compactForModelContext(short), short)

        let long = String(repeating: "字", count: 5000)
        let compacted = LingShuState.compactForModelContext(long)
        XCTAssertTrue(compacted.hasSuffix("…（节选）"))
        XCTAssertLessThan(compacted.count, long.count)
    }
}
