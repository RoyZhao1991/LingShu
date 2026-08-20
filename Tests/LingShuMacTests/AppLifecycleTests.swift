import AppKit
import XCTest
@testable import LingShuMac

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testMandatorySetupDoesNotBlockSystemQuit() {
        let delegate = LingShuAppDelegate()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}
