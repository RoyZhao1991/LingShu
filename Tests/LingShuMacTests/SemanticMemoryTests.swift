import XCTest
@testable import LingShuMac

final class SemanticMemoryTests: XCTestCase {
    private var store: LingShuSemanticMemoryStore!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-semantic-tests-\(UUID().uuidString)", isDirectory: true)
        store = LingShuSemanticMemoryStore(directory: directory)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testRememberAndRecallByChineseKeyword() {
        store.remember(kind: "任务执行", title: "灵枢周报整理", content: "把销售数据整理成周报，放到桌面。", tags: ["周报"])
        store.remember(kind: "普通对话", title: "天气闲聊", content: "聊了一下杭州的天气。", tags: [])

        let hits = store.recall(query: "上次让你整理的周报")
        XCTAssertFalse(hits.isEmpty, "中文 bigram 切词后应能命中「周报」")
        XCTAssertEqual(hits.first?.entry.title, "灵枢周报整理")
    }

    // MARK: - 幽灵相似度校准（NLEmbedding 改进）

    func testShortUnrelatedQueryDoesNotGhostMatch() {
        // 极短且无字面重叠的查询不应靠本地向量虚高命中无关条目（长度闸门 + 全文无重叠）。
        store.remember(kind: "任务执行", title: "量子纠错研究", content: "整理量子计算纠错码的研究笔记。", tags: ["量子"])
        let hits = store.recall(query: "在吗")
        XCTAssertTrue(hits.isEmpty, "2 字无关查询触发长度闸门、向量路跳过，不应命中")
    }

    func testRelatedQueryStillRecallsAfterGhostGuards() {
        // 回归：抬高余弦阈值 + 剥离填充词后，含"帮我/一下"的换措辞召回仍有效（全文 bigram 锚点）。
        store.remember(kind: "任务执行", title: "销售周报", content: "把上周销售数据整理成周报。", tags: ["周报"])
        let hits = store.recall(query: "帮我整理一下销售周报")
        XCTAssertEqual(hits.first?.entry.title, "销售周报", "填充词不该挡住真实召回")
    }

    func testSameKindAndTitleUpserts() {
        store.remember(kind: "研究课题", title: "上下文压缩", content: "第一版结论。")
        store.remember(kind: "研究课题", title: "上下文压缩", content: "第二版结论，更完整。")

        XCTAssertEqual(store.count, 1, "同 kind+title 应更新而不是重复插入")
        let hits = store.recall(query: "上下文压缩")
        XCTAssertEqual(hits.first?.entry.content, "第二版结论，更完整。")
    }

    func testRecallReturnsEmptyForBlankQuery() {
        store.remember(kind: "普通对话", title: "测试", content: "内容")
        XCTAssertTrue(store.recall(query: "   ").isEmpty)
    }

    func testEnglishKeywordRecall() {
        store.remember(kind: "软件工程", title: "SwiftUI 渲染优化", content: "LazyVStack avoids full rebuild of chat bubbles.")
        let hits = store.recall(query: "LazyVStack 优化")
        XCTAssertEqual(hits.first?.entry.title, "SwiftUI 渲染优化")
    }

    func testSearchTokensBigramsChineseAndKeepsLatinWords() {
        XCTAssertEqual(
            LingShuMemoryTextToolkit.searchTokens("灵枢项目 SwiftUI"),
            ["灵枢", "枢项", "项目", "swiftui"]
        )
        XCTAssertEqual(LingShuMemoryTextToolkit.searchTokens("枢"), ["枢"])
        XCTAssertEqual(LingShuMemoryTextToolkit.searchTokens("a。b"), ["a", "b"])
    }
}

final class ContextCompressionEngineTests: XCTestCase {
    private func msg(_ text: String, user: Bool) -> ChatMessage {
        ChatMessage(speaker: user ? "你" : "灵枢", text: text, isUser: user)
    }

    private let identity: (String) -> String = { $0 }

    func testUnderBudgetKeepsEverythingVerbatimWithoutDigest() {
        let messages = [msg("问题", user: true), msg("回答", user: false)]
        let composition = LingShuContextCompressionEngine.compose(
            messages: messages,
            budget: 16000,
            excludingTrailingPromptMatching: nil,
            normalize: identity,
            compact: { $0 }
        )
        XCTAssertEqual(composition.digest, "")
        XCTAssertEqual(composition.foldedTurnCount, 0)
        XCTAssertEqual(composition.verbatim.map(\.content), ["问题", "回答"])
    }

    func testOverBudgetFoldsOldTurnsIntoDigestInsteadOfDropping() {
        let messages = (1...20).map { msg("第\($0)轮消息内容占位填充", user: $0 % 2 == 1) }
        let composition = LingShuContextCompressionEngine.compose(
            messages: messages,
            budget: 90,
            excludingTrailingPromptMatching: nil,
            normalize: identity,
            compact: { $0 }
        )
        XCTAssertFalse(composition.digest.isEmpty, "被折叠的旧轮次必须进入摘要而不是凭空消失")
        XCTAssertTrue(composition.digest.contains("第1轮"), "摘要应包含最早轮次的线索")
        XCTAssertEqual(composition.foldedTurnCount % LingShuContextCompressionEngine.foldBlockSize, 0, "折叠边界按块对齐以稳定前缀")
        XCTAssertEqual(composition.verbatim.last?.content, "第20轮消息内容占位填充", "最近一轮必须原文保留")
    }

    func testDigestMessagesUseUserRoleNotSystem() {
        let pair = LingShuContextCompressionEngine.digestMessages(from: "你：要做周报\n灵枢：已完成")
        XCTAssertEqual(pair.count, 2)
        XCTAssertEqual(pair.first?.role, "user", "system 角色会顶掉网关主提示，压缩记忆必须走 user 角色")
        XCTAssertEqual(pair.last?.role, "assistant")
        XCTAssertTrue(pair.first?.content.contains("要做周报") == true)
    }

    func testWindowIntegrationProducesDigestPlusVerbatim() {
        let messages = (1...20).map { msg("第\($0)轮消息内容占位填充", user: $0 % 2 == 1) }
        let window = LingShuState.conversationWindow(
            from: messages,
            budget: 90,
            excludingTrailingPromptMatching: nil,
            normalize: identity,
            compact: { $0 }
        )
        XCTAssertTrue(window.first?.content.contains("压缩记忆") == true)
        XCTAssertEqual(window.last?.content, "第20轮消息内容占位填充")
    }
}
