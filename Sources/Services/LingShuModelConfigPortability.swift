import Foundation
import CryptoKit

/// 一份可移植的「大模型配置」快照:接入的各通道(名/端点/模型)+ 密钥 + 当前选用的脑。
/// 用于**加密导出 → 换台机器一键导入即用**(分享试用 / 开源时不泄密)。纯值类型,Codable,可单测。
struct LingShuModelConfigBundle: Codable, Equatable, Sendable {
    var version: Int = 1
    var provider: String                          // 当前选用的中枢(脑)供应商名
    var model: String                             // 当前模型名
    var endpoint: String                          // 当前中枢端点
    var channels: [String: ModelChannelConfig]    // 各能力通道(脑/眼/耳/口)的 名/端点/模型
    var credentials: [String: String]             // 各通道/供应商的密钥(key/token)——**导出时即明文,靠口令加密保护整个文件**
    var exportedAt: Date = Date()
    var note: String = ""

    /// 不含密钥的脱敏摘要(供 UI/日志展示"导出了什么",绝不打印明文)。
    var redactedSummary: String {
        "脑=\(provider)/\(model) · 通道 \(channels.count) 个 · 密钥 \(credentials.count) 条"
    }
}

/// # 大模型配置加密导入导出(纯逻辑可单测)—— 方案:数据安全 + 可分享 + 可开源
///
/// 设计要点:
/// - **口令加密(非本机绑定)**:与凭据库的"本机硬件 UUID 派生密钥"(换机解不开)不同,这里用**用户口令**经
///   PBKDF2-HMAC-SHA256 派生密钥再 AES-GCM 加密——这样导出文件**换台机器、给别人也能用同一口令解开**,
///   同时没口令谁也解不开(开源/分享安全)。
/// - 文件信封自带 KDF 参数(盐 + 迭代数),解密侧据此复现密钥;口令错/文件被改 → GCM 校验失败 → 报错不泄露。
enum LingShuModelConfigPortability {

    /// PBKDF2 迭代数(抗暴力;200k 在本机 < 1s,攻击者离线爆破成本高)。
    static let iterations = 200_000
    /// 口令最短长度(太短的口令保护不了)。
    static let minPassphraseLength = 8

    enum PortError: Error, Equatable, LocalizedError {
        case weakPassphrase
        case encodeFailed
        case badFile
        case wrongPassphraseOrCorrupt
        var errorDescription: String? {
            switch self {
            case .weakPassphrase: "口令太短(至少 \(LingShuModelConfigPortability.minPassphraseLength) 位)"
            case .encodeFailed: "配置序列化失败"
            case .badFile: "不是合法的灵枢配置文件(信封损坏)"
            case .wrongPassphraseOrCorrupt: "口令错误或文件已被篡改/损坏"
            }
        }
    }

    /// 加密信封(落盘 JSON):KDF 参数公开(盐/迭代数无需保密),`data` = base64(AES-GCM combined:nonce+密文+tag)。
    struct Envelope: Codable, Equatable {
        var v: Int
        var app: String         // 标识来源,便于人/程序识别
        var kdf: String         // "pbkdf2-hmac-sha256"
        var iter: Int
        var salt: String        // base64
        var data: String        // base64(AES-GCM combined)
    }

    // MARK: - 导出 / 导入

    static func export(_ bundle: LingShuModelConfigBundle, passphrase: String) throws -> Data {
        guard passphrase.count >= minPassphraseLength else { throw PortError.weakPassphrase }
        let salt = randomBytes(16)
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let plain = try? encoder.encode(bundle),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { throw PortError.encodeFailed }
        let env = Envelope(v: 1, app: "lingshu-model-config", kdf: "pbkdf2-hmac-sha256",
                           iter: iterations, salt: salt.base64EncodedString(), data: sealed.base64EncodedString())
        let outEncoder = JSONEncoder(); outEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? outEncoder.encode(env) else { throw PortError.encodeFailed }
        return out
    }

    static func importBundle(_ fileData: Data, passphrase: String) throws -> LingShuModelConfigBundle {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: fileData),
              let salt = Data(base64Encoded: env.salt),
              let sealedData = Data(base64Encoded: env.data) else { throw PortError.badFile }
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: max(1, env.iter))
        guard let box = try? AES.GCM.SealedBox(combined: sealedData),
              let plain = try? AES.GCM.open(box, using: key) else { throw PortError.wrongPassphraseOrCorrupt }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(LingShuModelConfigBundle.self, from: plain) else {
            throw PortError.wrongPassphraseOrCorrupt
        }
        return bundle
    }

    // MARK: - KDF(PBKDF2-HMAC-SHA256,纯 CryptoKit 实现,单块 dkLen=32)

    /// 由口令 + 盐 + 迭代数派生 256-bit 对称密钥(单块即满足 32 字节)。无 CommonCrypto 依赖。
    static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        let pwKey = SymmetricKey(data: Data(passphrase.utf8))
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])   // INT_32_BE(1):第一个(也是唯一)输出块
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: pwKey))
        var t = u
        var i = 1
        while i < iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: pwKey))
            for j in 0..<t.count { t[j] ^= u[j] }
            i += 1
        }
        return SymmetricKey(data: t)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
