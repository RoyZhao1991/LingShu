import Darwin
import XCTest
@testable import LingShuMac

final class CleanUserSmokeTests: XCTestCase {
    func testConfigurationAcceptsOneDisposableRoot() throws {
        let root = "/tmp/lingshu-clean-user-smoke.valid"
        let configuration = try LingShuRuntimeEnvironment.CleanUserSmokeConfiguration(environment: [
            "LINGSHU_CLEAN_USER_SMOKE": "1",
            "LINGSHU_CLEAN_USER_ROOT": root,
            "LINGSHU_CLEAN_USER_RESULT": root + "/evidence/result.json",
            "LINGSHU_CLEAN_USER_SOURCE": "unit-test",
            "HOME": root,
            "CFFIXED_USER_HOME": root
        ])

        XCTAssertEqual(configuration.root.path, root)
        XCTAssertEqual(configuration.resultFile.path, root + "/evidence/result.json")
        XCTAssertEqual(configuration.source, "unit-test")
    }

    func testConfigurationRejectsRealHomeAndPreferenceLeakage() {
        XCTAssertThrowsError(try LingShuRuntimeEnvironment.CleanUserSmokeConfiguration(environment: [
            "LINGSHU_CLEAN_USER_SMOKE": "1",
            "LINGSHU_CLEAN_USER_ROOT": "/Users/example",
            "HOME": "/Users/example",
            "CFFIXED_USER_HOME": "/Users/example"
        ])) { error in
            XCTAssertEqual(error as? LingShuRuntimeEnvironment.ConfigurationError, .unsafeRoot("/Users/example"))
        }

        XCTAssertThrowsError(try LingShuRuntimeEnvironment.CleanUserSmokeConfiguration(environment: [
            "LINGSHU_CLEAN_USER_SMOKE": "1",
            "LINGSHU_CLEAN_USER_ROOT": "/tmp/lingshu-clean-user-smoke.mismatch",
            "HOME": "/tmp/lingshu-clean-user-smoke.mismatch",
            "CFFIXED_USER_HOME": "/Users/example"
        ])) { error in
            XCTAssertEqual(error as? LingShuRuntimeEnvironment.ConfigurationError, .preferencesNotIsolated)
        }
    }

    func testConfigurationRejectsResultOutsideDisposableRoot() {
        XCTAssertThrowsError(try LingShuRuntimeEnvironment.CleanUserSmokeConfiguration(environment: [
            "LINGSHU_CLEAN_USER_SMOKE": "1",
            "LINGSHU_CLEAN_USER_ROOT": "/tmp/lingshu-clean-user-smoke.result",
            "LINGSHU_CLEAN_USER_RESULT": "/tmp/result.json",
            "HOME": "/tmp/lingshu-clean-user-smoke.result",
            "CFFIXED_USER_HOME": "/tmp/lingshu-clean-user-smoke.result"
        ])) { error in
            XCTAssertEqual(
                error as? LingShuRuntimeEnvironment.ConfigurationError,
                .resultOutsideRoot("/tmp/result.json")
            )
        }
    }

    func testEphemeralCredentialStoreIgnoresEnvironmentAndDisk() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-clean-user-smoke.credential-\(UUID().uuidString)", isDirectory: true)
        let provider = "clean-smoke-\(UUID().uuidString)"
        let environmentKey = LingShuCredentialStore.environmentKey(forProvider: provider)
        setenv(environmentKey, "must-not-be-read", 1)
        defer {
            unsetenv(environmentKey)
            try? FileManager.default.removeItem(at: root)
        }

        let store = LingShuCredentialStore(directory: root, ephemeral: true)

        XCTAssertTrue(store.usesEphemeralBackend)
        XCTAssertNil(store.apiKey(forProvider: provider))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        XCTAssertTrue(store.setAPIKey("temporary-only", forProvider: provider))
        XCTAssertEqual(store.apiKey(forProvider: provider), "temporary-only")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
