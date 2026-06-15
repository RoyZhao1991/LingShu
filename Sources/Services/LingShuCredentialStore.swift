import Foundation
import Security
import CryptoKit

/// 本地凭据仓库（灵枢自有配置文件实现，**加密落盘**）。
///
/// 凭据按 provider id 存进灵枢自己的配置目录
/// `~/Library/Application Support/LingShu/Credentials/credentials.json`（文件权限 0600，仅当前用户可读）。
/// 文件内容用 **AES-GCM 加密**：密钥由本机硬件 UUID（`gethostuuid`）+ 固定盐经 SHA-256 派生，
/// 不入仓库、不写 UserDefaults，复制到别的机器也解不开。
/// 读取顺序：内存缓存 → 加密配置文件 → 旧明文配置（一次性升级）→ 旧钥匙串（**静默**一次性迁移，
/// 永不弹框）→ 环境变量（`LINGSHU_TOKEN_<PROVIDER_ID>`，id 中的 `-` 换成 `_` 并大写，便于 CI/调试注入）。
///
/// 为什么不用钥匙串：灵枢是 ad-hoc 签名，签名每次重建都变，导致读钥匙串项每次都要弹框授权——
/// 反复摩擦，还卡住网关 TTS token。改存灵枢自有加密配置后：应用自有、启动不弹框、跨重建稳定。
/// 旧钥匙串里的凭据**静默**（`kSecUseAuthenticationUISkip`，需要弹框时直接失败而非打扰用户）
/// 首次访问时自动迁移进来，之后不再碰钥匙串。
final class LingShuCredentialStore: @unchecked Sendable {
    private let legacyKeychainService: String
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    init(service: String = "cn.lingshu.model-credentials", directory: URL? = nil) {
        self.legacyKeychainService = service
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingShu/Credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("credentials.json")
        loadFile()
    }

    func apiKey(forProvider providerID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[providerID] {
            return cached.isEmpty ? nil : cached
        }
        // 一次性迁移：旧凭据在钥匙串里 → 静默读出来写进加密配置，以后这个 provider 不再碰钥匙串。
        if let migrated = readFromKeychain(account: providerID), !migrated.isEmpty {
            cache[providerID] = migrated
            persist()
            return migrated
        }
        if let env = ProcessInfo.processInfo.environment[Self.environmentKey(forProvider: providerID)],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            cache[providerID] = trimmed
            return trimmed
        }
        cache[providerID] = ""
        return nil
    }

    func setAPIKey(_ key: String, forProvider providerID: String) {
        lock.lock()
        defer { lock.unlock() }

        cache[providerID] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    /// 已存的 provider id 列表(**只返回 key 名,绝不返回明文值**)。供凭据四肢 list_credentials 用。
    func providerIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return cache.filter { !$0.value.isEmpty }.keys.sorted()
    }

    static func environmentKey(forProvider providerID: String) -> String {
        "LINGSHU_TOKEN_" + providerID.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - 加密配置文件（灵枢自有）

    /// 落盘信封：版本号 + base64(AES-GCM combined)。旧明文文件没有这层信封，靠 `loadFile` 兼容升级。
    private struct Envelope: Codable {
        var v: Int
        var data: String
    }

    private func loadFile() {
        guard let raw = try? Data(contentsOf: fileURL) else { return }

        // 新格式：加密信封 → 解密。
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: raw),
           envelope.v >= 2,
           let sealed = Data(base64Encoded: envelope.data),
           let plain = Self.decrypt(sealed),
           let dict = try? JSONDecoder().decode([String: String].self, from: plain) {
            cache = dict
            return
        }

        // 旧格式：明文 [String: String] → 读出来后立即重写为加密格式（一次性升级）。
        if let dict = try? JSONDecoder().decode([String: String].self, from: raw) {
            cache = dict
            persist()
        }
    }

    private func persist() {
        let stored = cache.filter { !$0.value.isEmpty }
        guard let plain = try? JSONEncoder().encode(stored),
              let sealed = Self.encrypt(plain) else { return }
        let envelope = Envelope(v: 2, data: sealed.base64EncodedString())
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - 本机绑定加密（AES-GCM，密钥不落盘）

    /// 本机派生密钥：硬件 UUID + 固定盐 → SHA-256。换机器解不开，无需弹框。
    private static let symmetricKey: SymmetricKey = {
        var seed = "cn.lingshu.credential-store.v2"
        var bytes = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        if bytes.withUnsafeMutableBufferPointer({ gethostuuid($0.baseAddress, &timeout) }) == 0 {
            seed += bytes.map { String(format: "%02x", $0) }.joined()
        }
        let digest = SHA256.hash(data: Data(seed.utf8))
        return SymmetricKey(data: digest)
    }()

    private static func encrypt(_ plain: Data) -> Data? {
        guard let sealed = try? AES.GCM.seal(plain, using: symmetricKey) else { return nil }
        return sealed.combined
    }

    private static func decrypt(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: symmetricKey) else { return nil }
        return plain
    }

    // MARK: - 旧钥匙串（仅静默一次性迁移读取，永不弹框）

    private func readFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // 关键：需要用户交互（输入钥匙串密码）时直接失败，绝不弹框打扰。
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }
}
