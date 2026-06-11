import Foundation
import Security

/// 本地凭据仓库（钥匙串实现）。
///
/// 网关 token 等敏感凭据按 provider id 存入 macOS 钥匙串（加密落盘），
/// 不进代码仓库、不写 UserDefaults、不落明文文件。
/// 读取顺序：内存缓存 → 钥匙串 → 环境变量（`LINGSHU_TOKEN_<PROVIDER_ID>`，
/// id 中的 `-` 换成 `_` 并大写），方便 CI 与本地调试注入。
final class LingShuCredentialStore: @unchecked Sendable {
    private let service: String
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    init(service: String = "cn.lingshu.model-credentials") {
        self.service = service
    }

    func apiKey(forProvider providerID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[providerID] {
            return cached.isEmpty ? nil : cached
        }
        if let key = readFromKeychain(account: providerID) {
            cache[providerID] = key
            return key
        }
        if let key = ProcessInfo.processInfo.environment[Self.environmentKey(forProvider: providerID)],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            cache[providerID] = trimmed
            return trimmed
        }
        cache[providerID] = ""
        return nil
    }

    func setAPIKey(_ key: String, forProvider providerID: String) {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        cache[providerID] = trimmed

        if trimmed.isEmpty {
            deleteFromKeychain(account: providerID)
        } else {
            writeToKeychain(account: providerID, value: trimmed)
        }
    }

    static func environmentKey(forProvider providerID: String) -> String {
        "LINGSHU_TOKEN_" + providerID.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - Keychain

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func readFromKeychain(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private func writeToKeychain(account: String, value: String) {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func deleteFromKeychain(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
