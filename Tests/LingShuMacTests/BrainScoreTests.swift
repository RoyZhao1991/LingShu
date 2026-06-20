import XCTest
@testable import LingShuMac

/// # 「大脑」评分测试(替代 TRUST):自主完成 +1 / 触发兜底 −1 / 换脑归零
final class BrainScoreTests: XCTestCase {

    func testTaskCompletedAddsOne() {
        let s = LingShuBrainScore(brainID: "DeepSeek|deepseek-chat").taskCompleted()
        XCTAssertEqual(s.score, 1)
        XCTAssertEqual(s.completed, 1)
        XCTAssertEqual(s.fallbacks, 0)
    }

    func testFallbackSubtractsOne() {
        let s = LingShuBrainScore(brainID: "X|y").fallbackTriggered()
        XCTAssertEqual(s.score, -1)
        XCTAssertEqual(s.fallbacks, 1)
    }

    func testNetAccumulation() {
        var s = LingShuBrainScore(brainID: "X|y")
        s = s.taskCompleted().taskCompleted().taskCompleted()   // +3
        s = s.fallbackTriggered().fallbackTriggered()           // -2
        XCTAssertEqual(s.score, 1, "3 完成 − 2 兜底 = 1")
        XCTAssertEqual(s.completed, 3)
        XCTAssertEqual(s.fallbacks, 2)
    }

    func testScoreCanGoNegativeForWeakBrain() {
        let s = LingShuBrainScore(brainID: "weak|m")
            .taskCompleted().fallbackTriggered().fallbackTriggered().fallbackTriggered()
        XCTAssertEqual(s.score, -2, "弱脑兜底多 → 负分(正是要看清的信号)")
    }

    // MARK: - 换脑归零

    func testRebaseResetsOnBrainChange() {
        let earned = LingShuBrainScore(brainID: "DeepSeek|deepseek-chat").taskCompleted().taskCompleted()
        // 同一颗脑 → 分数保留
        XCTAssertEqual(earned.rebased(to: "DeepSeek|deepseek-chat"), earned)
        // 换脑 → 归零(新脑全新 0 分)
        let switched = earned.rebased(to: "MiniMax|abab6")
        XCTAssertEqual(switched.score, 0)
        XCTAssertEqual(switched.completed, 0)
        XCTAssertEqual(switched.fallbacks, 0)
        XCTAssertEqual(switched.brainID, "MiniMax|abab6")
    }

    func testBrainIDFormat() {
        XCTAssertEqual(LingShuBrainScore.id(provider: "DeepSeek", model: "deepseek-chat"), "DeepSeek|deepseek-chat")
    }

    func testSummaryShowsBreakdown() {
        let s = LingShuBrainScore(brainID: "X|y").taskCompleted().taskCompleted().fallbackTriggered()
        XCTAssertTrue(s.summary.contains("1"))           // score
        XCTAssertTrue(s.summary.contains("+2"))          // completed
        XCTAssertTrue(s.summary.contains("−1") || s.summary.contains("-1"))  // fallbacks
    }

    // MARK: - Codable 往返(持久化)

    func testCodableRoundTrip() throws {
        let s = LingShuBrainScore(brainID: "X|y", score: 5, completed: 7, fallbacks: 2)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(LingShuBrainScore.self, from: data)
        XCTAssertEqual(back, s)
    }
}
