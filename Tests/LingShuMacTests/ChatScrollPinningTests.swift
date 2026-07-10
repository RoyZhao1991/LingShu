import XCTest
@testable import LingShuMac

final class ChatScrollPinningTests: XCTestCase {
    func testFlippedDocumentAtBottomWithinThreshold() {
        XCTAssertTrue(LingShuChatScrollPinning.isAtBottom(
            documentBounds: CGRect(x: 0, y: 0, width: 800, height: 1_000),
            visibleBounds: CGRect(x: 0, y: 572, width: 800, height: 400),
            documentIsFlipped: true
        ))
    }

    func testFlippedDocumentScrolledUpDoesNotFollow() {
        XCTAssertFalse(LingShuChatScrollPinning.isAtBottom(
            documentBounds: CGRect(x: 0, y: 0, width: 800, height: 1_000),
            visibleBounds: CGRect(x: 0, y: 450, width: 800, height: 400),
            documentIsFlipped: true
        ))
    }

    func testShortDocumentIsAlwaysPinned() {
        XCTAssertTrue(LingShuChatScrollPinning.isAtBottom(
            documentBounds: CGRect(x: 0, y: 0, width: 800, height: 300),
            visibleBounds: CGRect(x: 0, y: 0, width: 800, height: 400),
            documentIsFlipped: true
        ))
    }

    func testNonFlippedDocumentUsesLowerEdgeAsBottom() {
        XCTAssertTrue(LingShuChatScrollPinning.isAtBottom(
            documentBounds: CGRect(x: 0, y: 0, width: 800, height: 1_000),
            visibleBounds: CGRect(x: 0, y: 12, width: 800, height: 400),
            documentIsFlipped: false
        ))
        XCTAssertFalse(LingShuChatScrollPinning.isAtBottom(
            documentBounds: CGRect(x: 0, y: 0, width: 800, height: 1_000),
            visibleBounds: CGRect(x: 0, y: 120, width: 800, height: 400),
            documentIsFlipped: false
        ))
    }
}
