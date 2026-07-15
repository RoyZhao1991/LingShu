import XCTest
@testable import LingShuMac

final class GoalSpecProgressCopyTests: XCTestCase {
    func testGoalSpecProgressDoesNotExposeInternalGenerationDetails() {
        let progress = LingShuState.goalSpecUserProgressMessage

        XCTAssertEqual(progress, "理解中…")
        XCTAssertFalse(progress.contains("GoalSpec"))
        XCTAssertFalse(progress.contains("1/3"))
        XCTAssertFalse(progress.contains("JSON"))
    }
}
