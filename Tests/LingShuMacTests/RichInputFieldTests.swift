import XCTest
@testable import LingShuMac

/// 富文本输入框的 `@别名` 内嵌 token 高亮范围识别(纯函数)。
final class RichInputFieldTests: XCTestCase {

    private func ranges(_ s: String, _ aliases: [String]) -> [NSRange] {
        LingShuRichInputField.Coordinator.mentionRanges(in: s, aliases: aliases)
    }

    func testHighlightsKnownAtAliases() {
        let s = "调用 @Codex 开发 @Claude 验收"
        let r = ranges(s, ["Codex", "Claude", "演示"])
        XCTAssertEqual(r.count, 2)
        let ns = s as NSString
        XCTAssertEqual(ns.substring(with: r[0]), "@Codex")
        XCTAssertEqual(ns.substring(with: r[1]), "@Claude")
    }

    func testLongestAliasMatchAvoidsPartialToken() {
        // 别名里既有"演示"也有"演示与答疑"时,@演示与答疑 应整体高亮(取最长命中)。
        let s = "@演示与答疑 这份PPT"
        let r = ranges(s, ["演示", "演示与答疑"])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual((s as NSString).substring(with: r[0]), "@演示与答疑")
    }

    func testIgnoresUnknownBareAtAndEmail() {
        XCTAssertTrue(ranges("@没注册的东西", ["Codex"]).isEmpty, "未知别名不高亮")
        XCTAssertTrue(ranges("调用 @", ["Codex"]).isEmpty, "光秃秃的 @ 不高亮")
        XCTAssertTrue(ranges("发到 roy@example.com", ["Codex"]).isEmpty, "邮箱 @ 后非别名不高亮")
        XCTAssertTrue(ranges("普通文字没有提及", ["Codex"]).isEmpty)
        XCTAssertTrue(ranges("@Codex", []).isEmpty, "无已知别名时不高亮")
    }

    // MARK: @ 自动补全的活跃 mention 检测

    private func mention(_ s: String, _ cursor: Int) -> LingShuMentionQuery? {
        LingShuRichInputField.Coordinator.activeMention(in: s as NSString, cursorLoc: cursor)
    }

    func testActiveMentionDetectsQuery() {
        // "调用 @c" 光标在末尾 → query="c",范围="@c"
        let r = mention("调用 @c", 5)
        XCTAssertEqual(r?.query, "c")
        XCTAssertEqual(("调用 @c" as NSString).substring(with: r!.range), "@c")
        // 刚打 @ → 空查询(弹全列表)
        XCTAssertEqual(mention("调用 @", 4)?.query, "")
    }

    func testActiveMentionNilWhenNotInMention() {
        XCTAssertNil(mention("@Codex 开发坦克", 9), "@后有空格再打字→不在 mention")
        XCTAssertNil(mention("a@b", 3), "@前非边界(邮箱)不算 mention")
        XCTAssertNil(mention("普通文字", 4), "没有 @ 不算")
        XCTAssertNil(mention("", 0))
    }

    @MainActor
    func testSendClearsInvocationHintChips() {
        let state = LingShuState()
        state.prompt = " "
        state.detectedInvocationChips = [
            .init(name: "Codex", role: "maker", isAgent: true)
        ]

        _ = state.sendPrompt()

        XCTAssertTrue(state.prompt.isEmpty)
        XCTAssertTrue(state.detectedInvocationChips.isEmpty, "发送后输入框上方的「将调用」提示必须清空")
    }
}
