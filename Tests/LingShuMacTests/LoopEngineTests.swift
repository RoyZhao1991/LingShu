import XCTest
@testable import LingShuMac

final class LoopEngineTests: XCTestCase {
    func testGrokAndCodexAreSameClassReplaceableLoopChoices() {
        XCTAssertEqual(LingShuLoopEngine.allCases, [.grok, .codex])
        XCTAssertEqual(LingShuLoopEngine.grok.displayName(language: .english), "Grok Loop (built in)")
        XCTAssertEqual(LingShuLoopEngine.codex.displayName(language: .english), "Codex Loop (managed)")
    }

    func testCleanAndLegacyPreferencesResolveToGrok() {
        XCTAssertEqual(LingShuLoopEngine.resolvePersisted(nil), .grok)
        XCTAssertEqual(LingShuLoopEngine.resolvePersisted("native"), .grok)
        XCTAssertEqual(LingShuLoopEngine.resolvePersisted("embeddedGrok"), .grok)
        XCTAssertEqual(LingShuLoopEngine.resolvePersisted("codex"), .codex)
    }
}
