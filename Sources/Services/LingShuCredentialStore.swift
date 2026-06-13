import Foundation
import Security

/// 本地凭据仓库（灵枢自有配置文件实现）。
///
/// 凭据按 provider id 存进灵枢自己的配置目录
/// `~/Library/Application Support/LingShu/Credentials/credentials.json`（文件权限 0600，仅当前用户可读）。
/// 读取顺序：内存缓存 → 配置文件 → 旧钥匙串（一次性迁移）→ 环境变量
/// （`LINGSHU_TOKEN_<PROVIDER_ID>`，id 中的 `-` 换成 `_` 并大写，便于 CI/调试注入）。
///
/// 为什么从钥匙串改成配置文件：灵枢是 ad-hoc 签名，签名每次重建都变，导致读钥匙串项每次都要
/// 重新弹框授权——反复摩擦，还多次卡住网关 TTS token 的读取。改存灵枢自有配置后：应用自有、
/// 启动不弹框、跨重建稳定。安全权衡：配置文件是**明文**（不再用钥匙串加密），个人本机工具可接受；
/// 仍不进代码仓库、不写 UserDefaults。旧钥匙串里的凭据首次访问时自动迁移进来，之后不再碰钥匙串。
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
        // 一次性迁移：旧凭据在钥匙串里 → 读出来写进配置文件，以后这个 provider 不再碰钥匙串。
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

    static func environmentKey(forProvider providerID: String) -> String {
        "LINGSHU_TOKEN_" + providerID.uppercased().replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - 配置文件（灵枢自有）

    private func loadFile() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        cache = dict
    }

    private func persist() {
        let stored = cache.filter { !$0.value.isEmpty }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - 旧钥匙串（仅一次性迁移读取）

    private func readFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
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
