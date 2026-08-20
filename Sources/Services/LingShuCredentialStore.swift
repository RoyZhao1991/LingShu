import Foundation
import Security
import CryptoKit

/// Local credential store backed by an app-owned, machine-bound AES-GCM envelope.
///
/// Production credentials never enter UserDefaults or a repository-visible file. The encrypted
/// envelope lives under Application Support with mode 0600 and does not depend on an unlocked
/// login Keychain. Production launch never reads Keychain; legacy import and `useKeychain: true`
/// remain explicit compatibility paths for migration tools and tests.
final class LingShuCredentialStore: @unchecked Sendable {
    private let service: String
    private let fileURL: URL
    private let keychainMigrationMarkerURL: URL
    private let usesKeychain: Bool
    private let isEphemeral: Bool
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var keychainReadsAvailable = true

    private final class KeychainCopyBox: @unchecked Sendable {
        let query: CFDictionary
        private let lock = NSLock()
        private var storedResult: (OSStatus, CFTypeRef?)?

        init(query: CFDictionary) {
            self.query = query
        }

        func store(status: OSStatus, item: CFTypeRef?) {
            lock.lock()
            storedResult = (status, item)
            lock.unlock()
        }

        func result() -> (OSStatus, CFTypeRef?)? {
            lock.lock()
            defer { lock.unlock() }
            return storedResult
        }
    }

    init(
        service: String = "cn.lingshu.model-credentials",
        directory: URL? = nil,
        useKeychain: Bool? = nil,
        ephemeral: Bool? = nil,
        importLegacyKeychain: Bool? = nil
    ) {
        let isEphemeral = ephemeral ?? LingShuRuntimeEnvironment.isCleanUserSmoke
        self.service = service
        self.isEphemeral = isEphemeral
        self.usesKeychain = !isEphemeral && (useKeychain ?? false)
        let base = directory ?? LingShuRuntimeEnvironment.homeDirectory
            .appendingPathComponent("Library/Application Support/LingShu/Credentials", isDirectory: true)
        self.fileURL = base.appendingPathComponent("credentials.json")
        self.keychainMigrationMarkerURL = base.appendingPathComponent(".keychain-imported-v3")
        guard !isEphemeral else { return }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if usesKeychain {
            cache = readAllFromKeychain()
            migrateLegacyFileIfNeeded()
        } else {
            loadFile()
            // Establish the app-owned backend before the optional Keychain import. A locked or
            // unavailable legacy Keychain must never leave the setup flow without writable storage.
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = persist()
            }
            if importLegacyKeychain == true {
                importKeychainOnceIfNeeded()
            }
        }
    }

    func apiKey(forProvider providerID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[providerID] {
            return cached.isEmpty ? nil : cached
        }
        if usesKeychain,
           keychainReadsAvailable,
           let stored = readFromKeychain(account: providerID),
           !stored.isEmpty {
            cache[providerID] = stored
            return stored
        }
        if !isEphemeral,
           let env = ProcessInfo.processInfo.environment[Self.environmentKey(forProvider: providerID)],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            cache[providerID] = trimmed
            return trimmed
        }
        cache[providerID] = ""
        return nil
    }

    @discardableResult
    func setAPIKey(_ key: String, forProvider providerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEphemeral {
            cache[providerID] = trimmed
            return true
        }
        if usesKeychain {
            let stored = trimmed.isEmpty
                ? deleteFromKeychain(account: providerID)
                : writeToKeychain(account: providerID, value: trimmed)
            guard stored else { return false }
            cache[providerID] = trimmed
            return true
        }

        let previous = cache[providerID]
        cache[providerID] = trimmed
        guard persist() else {
            if let previous {
                cache[providerID] = previous
            } else {
                cache.removeValue(forKey: providerID)
            }
            return false
        }
        return true
    }

    /// 已存的 provider id 列表(**只返回 key 名,绝不返回明文值**)。供凭据四肢 list_credentials 用。
    func providerIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return cache.filter { !$0.value.isEmpty }.keys.sorted()
    }

    /// **全部已存凭据(含明文值)**。仅供「加密配置导出」整体打包用——导出后立刻经口令 AES-GCM 加密,
    /// 绝不以明文落盘/回显。其它任何场景都用 `providerIDs()`(只名不值)。
    func allCredentials() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return cache.filter { !$0.value.isEmpty }
    }

    /// 批量写入凭据(供「加密配置导入」一次性恢复)。生产环境使用本机绑定 AES-GCM；
    /// 显式 `useKeychain: true` 的兼容测试仍写入 Keychain。
    func bulkSet(_ entries: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        for (id, value) in entries {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { continue }
            if isEphemeral || !usesKeychain || writeToKeychain(account: id, value: v) {
                cache[id] = v
            }
        }
        if !usesKeychain, !isEphemeral { _ = persist() }
    }

    var usesEphemeralBackend: Bool { isEphemeral }

    static func environmentKey(forProvider providerID: String) -> String {
        "LINGSHU_TOKEN_" + providerID.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - Legacy/test encrypted file

    /// 落盘信封：版本号 + base64(AES-GCM combined)。旧明文文件没有这层信封，靠 `loadFile` 兼容升级。
    private struct Envelope: Codable {
        var v: Int
        var data: String
    }

    private func loadFile() {
        guard let values = Self.decodeLegacyFile(at: fileURL) else { return }
        cache = values
        _ = persist() // Plain v1 files are immediately rewritten as an encrypted envelope.
    }

    @discardableResult
    private func persist() -> Bool {
        let stored = cache.filter { !$0.value.isEmpty }
        guard let plain = try? JSONEncoder().encode(stored),
              let sealed = Self.encrypt(plain) else { return false }
        let envelope = Envelope(v: 2, data: sealed.base64EncodedString())
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }

    /// 从旧版本 Keychain 一次性导入应用自己的加密凭据库。读取禁用授权 UI，失败时不写
    /// marker，下一次启动仍可重试；成功读取后只补齐缺失项，不覆盖用户已在新库保存的值。
    private func importKeychainOnceIfNeeded() {
        let hasMarker = FileManager.default.fileExists(atPath: keychainMigrationMarkerURL.path)
        let hasCredentialFile = FileManager.default.fileExists(atPath: fileURL.path)
        guard !(hasMarker && hasCredentialFile) else { return }
        if hasMarker {
            try? FileManager.default.removeItem(at: keychainMigrationMarkerURL)
        }
        let legacyValues = readAllFromKeychain()
        guard keychainReadsAvailable else { return }

        for (providerID, value) in legacyValues
            where !value.isEmpty && cache[providerID]?.isEmpty != false {
            cache[providerID] = value
        }
        guard persist() else {
            cache = Self.decodeLegacyFile(at: fileURL) ?? [:]
            return
        }

        let marker = Data("imported".utf8)
        do {
            try marker.write(to: keychainMigrationMarkerURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keychainMigrationMarkerURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: keychainMigrationMarkerURL)
        }
    }

    private func migrateLegacyFileIfNeeded() {
        guard let values = Self.decodeLegacyFile(at: fileURL), !values.isEmpty else { return }
        var migratedAll = true
        for (providerID, value) in values where !value.isEmpty {
            if writeToKeychain(account: providerID, value: value) {
                cache[providerID] = value
            } else {
                migratedAll = false
            }
        }
        if migratedAll {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func decodeLegacyFile(at url: URL) -> [String: String]? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: raw),
           envelope.v >= 2,
           let sealed = Data(base64Encoded: envelope.data),
           let plain = decrypt(sealed),
           let values = try? JSONDecoder().decode([String: String].self, from: plain) {
            return values
        }
        return try? JSONDecoder().decode([String: String].self, from: raw)
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

    // MARK: - Keychain

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private func readFromKeychain(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        guard let (status, item) = copyMatchingWithoutBlockingLaunch(query) else {
            return nil
        }
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                keychainReadsAvailable = false
            }
            return nil
        }
        guard
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private func readAllFromKeychain() -> [String: String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        guard let (status, item) = copyMatchingWithoutBlockingLaunch(query) else {
            return [:]
        }
        if status == errSecItemNotFound {
            return [:]
        }
        guard status == errSecSuccess else {
            keychainReadsAvailable = false
            return [:]
        }
        let rows: [[String: Any]]
        if let multiple = item as? [[String: Any]] {
            rows = multiple
        } else if let single = item as? [String: Any] {
            // Security.framework may return one dictionary instead of an array when only one
            // generic-password item matches, even with kSecMatchLimitAll.
            rows = [single]
        } else {
            keychainReadsAvailable = false
            return [:]
        }

        var values: [String: String] = [:]
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String,
                  let value = readFromKeychain(account: account),
                  !value.isEmpty else { continue }
            values[account] = value
        }
        return values
    }

    /// A locked or legacy Keychain item must never prevent SwiftUI from creating its first window.
    /// Security.framework can occasionally ignore `kSecUseAuthenticationUISkip` and wait for an
    /// invisible authorization agent. Run reads off the caller thread and fail closed after a short
    /// deadline; credentials stay in Keychain and can be retried after the next app launch.
    private func copyMatchingWithoutBlockingLaunch(
        _ query: [String: Any],
        timeout: TimeInterval = 1.5
    ) -> (OSStatus, CFTypeRef?)? {
        let box = KeychainCopyBox(query: query as CFDictionary)
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(box.query, &item)
            box.store(status: status, item: item)
            completion.signal()
        }

        guard completion.wait(timeout: .now() + timeout) == .success else {
            keychainReadsAvailable = false
            return nil
        }
        return box.result()
    }

    private func writeToKeychain(account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private func deleteFromKeychain(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
