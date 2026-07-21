import XCTest
@testable import LingShuMac

final class LoopEngineTests: XCTestCase {
    func testOnlyEmbeddedRuntimeIsExposedAsNativeLoop() {
        XCTAssertEqual(LingShuLoopEngine.allCases, [.native])
        XCTAssertEqual(LingShuLoopEngine.native.rawValue, "embeddedGrok")
        XCTAssertEqual(LingShuLoopEngine.native.displayName(language: .chinese), "灵枢原生 Loop")
        XCTAssertEqual(LingShuLoopEngine.native.displayName(language: .english), "LingShu Native Loop")
    }

    func testCleanAndLegacyPreferencesResolveToEmbeddedRuntime() {
        XCTAssertEqual(LingShuLoopEngine.resolvePersisted(nil), .native)
        XCTAssertEqual(LingShuLoopEngine.resolvePersisted("native"), .native)
        XCTAssertEqual(LingShuLoopEngine.resolvePersisted("embeddedGrok"), .native)
    }
}
