import XCTest
@testable import LingShuMac

/// # 大模型配置加密导入导出测试 —— 数据安全 + 可分享 + 可开源
///
/// 守住:① 口令往返无损 ② 口令错/篡改解不开 ③ 弱口令拒绝 ④ 文件里**绝无明文密钥**(开源/分享安全)⑤ KDF 确定性。
final class ModelConfigPortabilityTests: XCTestCase {

    private func sampleBundle() -> LingShuModelConfigBundle {
        LingShuModelConfigBundle(
            provider: "DeepSeek", model: "deepseek-chat", endpoint: "https://api.deepseek.com/v1",
            channels: ["brain:DeepSeek": ModelChannelConfig(name: "主脑", endpoint: "https://api.deepseek.com/v1", model: "deepseek-chat"),
                       "tts:cosy": ModelChannelConfig(name: "情绪语音", endpoint: "https://gw/tts", model: "cosyvoice2")],
            credentials: ["DeepSeek": "sk-SUPERSECRET-abc123", "datanet-gateway": "tok-XYZ-987"],
            note: "test")
    }

    // MARK: - ① 口令往返无损

    func testRoundTripPreservesEverything() throws {
        let bundle = sampleBundle()
        let blob = try LingShuModelConfigPortability.export(bundle, passphrase: "trial-pass-2026")
        let restored = try LingShuModelConfigPortability.importBundle(blob, passphrase: "trial-pass-2026")
        XCTAssertEqual(restored.provider, bundle.provider)
        XCTAssertEqual(restored.model, bundle.model)
        XCTAssertEqual(restored.endpoint, bundle.endpoint)
        XCTAssertEqual(restored.channels, bundle.channels)
        XCTAssertEqual(restored.credentials, bundle.credentials, "密钥逐条恢复")
    }

    // MARK: - ② 口令错 / 篡改 → 解不开

    func testWrongPassphraseFails() throws {
        let blob = try LingShuModelConfigPortability.export(sampleBundle(), passphrase: "correct-horse")
        XCTAssertThrowsError(try LingShuModelConfigPortability.importBundle(blob, passphrase: "wrong-horse")) { e in
            XCTAssertEqual(e as? LingShuModelConfigPortability.PortError, .wrongPassphraseOrCorrupt)
        }
    }

    func testTamperedFileFails() throws {
        var blob = try LingShuModelConfigPortability.export(sampleBundle(), passphrase: "correct-horse")
        // 翻转密文里某个字节(信封 data 字段的 base64 内容)→ GCM 校验必败。
        if let range = blob.range(of: Data("\"data\" :".utf8)) ?? blob.range(of: Data("\"data\":".utf8)) {
            let idx = blob.index(range.upperBound, offsetBy: 6)
            blob[idx] = blob[idx] == 65 ? 66 : 65   // 'A'<->'B'
        } else {
            blob[blob.count / 2] ^= 0xFF
        }
        XCTAssertThrowsError(try LingShuModelConfigPortability.importBundle(blob, passphrase: "correct-horse"))
    }

    // MARK: - ③ 弱口令拒绝

    func testWeakPassphraseRejected() {
        XCTAssertThrowsError(try LingShuModelConfigPortability.export(sampleBundle(), passphrase: "short")) { e in
            XCTAssertEqual(e as? LingShuModelConfigPortability.PortError, .weakPassphrase)
        }
    }

    // MARK: - ④ 导出文件里绝无明文密钥(开源/分享安全的核心)

    func testExportedBlobLeaksNoPlaintextSecret() throws {
        let blob = try LingShuModelConfigPortability.export(sampleBundle(), passphrase: "trial-pass-2026")
        let text = String(data: blob, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("sk-SUPERSECRET-abc123"), "明文密钥绝不能出现在导出文件里")
        XCTAssertFalse(text.contains("tok-XYZ-987"))
        XCTAssertFalse(text.contains("deepseek-chat"), "连端点/模型这类配置也在密文内,不泄露")
        XCTAssertTrue(text.contains("pbkdf2"), "信封含公开的 KDF 参数")
    }

    // MARK: - ⑤ KDF 确定性(同口令+盐+迭代→同密钥)

    func testKDFDeterministic() {
        let salt = Data([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16])
        let k1 = LingShuModelConfigPortability.deriveKey(passphrase: "abc", salt: salt, iterations: 1000)
        let k2 = LingShuModelConfigPortability.deriveKey(passphrase: "abc", salt: salt, iterations: 1000)
        let k3 = LingShuModelConfigPortability.deriveKey(passphrase: "abd", salt: salt, iterations: 1000)
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3, "口令不同 → 密钥不同")
    }

    // MARK: - ⑥ 空配置也能往返(无密钥时不崩)

    func testEmptyBundleRoundTrips() throws {
        let empty = LingShuModelConfigBundle(provider: "X", model: "m", endpoint: "e", channels: [:], credentials: [:])
        let blob = try LingShuModelConfigPortability.export(empty, passphrase: "passphrase1")
        let back = try LingShuModelConfigPortability.importBundle(blob, passphrase: "passphrase1")
        XCTAssertTrue(back.credentials.isEmpty)
        XCTAssertEqual(back.provider, "X")
    }
}
