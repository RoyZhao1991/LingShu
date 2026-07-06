import XCTest
@testable import LingShuMac

final class ConversationHistorySearchTests: XCTestCase {
    func testSearchCoversHotAndColdChat() {
        let hot = ChatMessage(
            speaker: "灵枢",
            text: "当前热记录里提到了 OAuth 授权流程。",
            isUser: false,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let cold = ChatMessage(
            speaker: "你",
            text: "冷备记录里保存了 PPT 演示方案。",
            isUser: true,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let allHits = LingShuConversationHistorySearch.search(
            keyword: "PPT",
            scope: .all,
            hotChat: [hot],
            coldChat: [cold],
            hotTaskRecords: [],
            coldTaskRecords: []
        )
        XCTAssertEqual(allHits.map(\.source), [.coldChat])

        let hotHits = LingShuConversationHistorySearch.search(
            keyword: "OAuth",
            scope: .hot,
            hotChat: [hot],
            coldChat: [cold],
            hotTaskRecords: [],
            coldTaskRecords: []
        )
        XCTAssertEqual(hotHits.map(\.source), [.hotChat])
    }

    func testSearchCoversHotAndColdTaskRecords() {
        let hotRecord = LingShuTaskExecutionRecord(
            id: "hot-task",
            title: "制作汇报材料",
            prompt: "生成 MEM 汇报 PPT",
            status: .completed,
            summary: "已经生成汇报材料。",
            participants: ["灵枢"],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300),
            messages: [
                .init(actor: "设计", role: "交付", kind: .result, text: "PPT 结构完成")
            ]
        )
        let coldRecord = LingShuTaskExecutionRecord(
            id: "cold-task",
            title: "同步 Notion",
            prompt: "同步今日待办到外部知识库",
            status: .waitingForUser,
            summary: "缺少 Notion token。",
            participants: ["灵枢"],
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 60),
            messages: [
                .init(actor: "工具", role: "缺口", kind: .warning, text: "需要 Notion 授权")
            ]
        )

        let hits = LingShuConversationHistorySearch.search(
            keyword: "Notion token",
            scope: .cold,
            hotChat: [],
            coldChat: [],
            hotTaskRecords: [hotRecord],
            coldTaskRecords: [coldRecord]
        )

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.source, .coldTask)
        XCTAssertEqual(hits.first?.recordID, "cold-task")
        XCTAssertTrue(hits.first?.snippet.contains("Notion") == true)
    }

    func testSearchRequiresAllTermsToAvoidNoisyHits() {
        let a = ChatMessage(speaker: "灵枢", text: "OAuth 只是协议说明。", isUser: false)
        let b = ChatMessage(speaker: "灵枢", text: "OAuth token 授权流程完整说明。", isUser: false)

        let hits = LingShuConversationHistorySearch.search(
            keyword: "OAuth token",
            scope: .all,
            hotChat: [a, b],
            coldChat: [],
            hotTaskRecords: [],
            coldTaskRecords: []
        )

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.snippet, "OAuth token 授权流程完整说明。")
    }
}
