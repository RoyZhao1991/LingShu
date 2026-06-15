import XCTest
@testable import LingShuMac

/// 凭据四肢测试(计划 §5,方案 B:大脑只见 key、不见明文)。
final class CredentialToolsTests: XCTestCase {

    private func makeStore() -> LingShuCredentialStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-cred-test-\(UUID().uuidString)", isDirectory: true)
        return LingShuCredentialStore(directory: dir)
    }

    func testStoreRoundTripAndListsKeyNamesOnly() {
        let store = makeStore()
        store.setAPIKey("ghp_secrettoken123", forProvider: LingShuState.userCredentialPrefix + "github")
        store.setAPIKey("sk-openaisecret", forProvider: LingShuState.userCredentialPrefix + "openai")

        // 取得真值(执行层注入用)。
        XCTAssertEqual(store.apiKey(forProvider: LingShuState.userCredentialPrefix + "github"), "ghp_secrettoken123")

        // 列表只返回 key 名,绝不含明文值。
        let ids = store.providerIDs()
        XCTAssertTrue(ids.contains(LingShuState.userCredentialPrefix + "github"))
        XCTAssertTrue(ids.contains(LingShuState.userCredentialPrefix + "openai"))
        for id in ids {
            XCTAssertFalse(id.contains("ghp_secrettoken123"), "key 名不应泄露明文")
            XCTAssertFalse(id.contains("sk-openaisecret"), "key 名不应泄露明文")
        }
    }

    func testRedactSecretsMasksPlaintext() {
        let output = "Authorization: Bearer ghp_secrettoken123\nstatus 200"
        let masked = LingShuState.redactSecrets(output, secrets: ["ghp_secrettoken123"])
        XCTAssertFalse(masked.contains("ghp_secrettoken123"), "输出里的明文必须被打码")
        XCTAssertTrue(masked.contains("***"))
        XCTAssertTrue(masked.contains("status 200"), "非秘密内容保留")
    }

    func testRedactSecretsNoOpWhenEmpty() {
        let text = "nothing secret here"
        XCTAssertEqual(LingShuState.redactSecrets(text, secrets: []), text)
    }

    func testNormalizeCredentialKeyCaseInsensitive() {
        XCTAssertEqual(LingShuState.normalizeCredentialKey(" GitHub "), "github")
        XCTAssertEqual(LingShuState.normalizeCredentialKey("OpenAI"), "openai")
    }
}
