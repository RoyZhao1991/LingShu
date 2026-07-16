import XCTest
@testable import LingShuMac

final class InitialLanguageSelectionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InitialLanguageSelectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testCleanInstallRequiresExplicitLanguageSelection() {
        XCTAssertFalse(LingShuLanguagePreferenceStore.hasCompletedInitialSelection(in: defaults))
    }

    func testExistingExplicitLanguagePreferenceMigratesWithoutPrompt() {
        defaults.set(LingShuVoiceLanguage.english.rawValue, forKey: LingShuLanguagePreferenceStore.languageKey)

        XCTAssertTrue(LingShuLanguagePreferenceStore.hasCompletedInitialSelection(in: defaults))
    }

    func testCompletionPersistsLanguageAndSelectionMarker() {
        LingShuLanguagePreferenceStore.completeInitialSelection(.english, in: defaults)

        XCTAssertEqual(defaults.string(forKey: LingShuLanguagePreferenceStore.languageKey), LingShuVoiceLanguage.english.rawValue)
        XCTAssertTrue(defaults.bool(forKey: LingShuLanguagePreferenceStore.initialSelectionKey))
        XCTAssertTrue(LingShuLanguagePreferenceStore.hasCompletedInitialSelection(in: defaults))
    }

    func testExplicitResetMarkerOverridesLegacyLanguageKey() {
        defaults.set(LingShuVoiceLanguage.chinese.rawValue, forKey: LingShuLanguagePreferenceStore.languageKey)
        defaults.set(false, forKey: LingShuLanguagePreferenceStore.initialSelectionKey)

        XCTAssertFalse(LingShuLanguagePreferenceStore.hasCompletedInitialSelection(in: defaults))
    }
}
