import Foundation

/// App 包内运行配置读取器。
///
/// 用于随安装包交付的内置能力凭据/端点配置，例如灵枢默认的模型网关 TTS。
/// 用户私有 API Key 仍应由单独的凭据仓库管理；这里不读取 Keychain，也不写 UserDefaults。
struct LingShuBundledRuntimeConfig {
    static let directoryName = "RuntimeConfig"

    private let bundle: Bundle
    private let fileManager: FileManager
    private let extraRoots: [URL]

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        extraRoots: [URL] = []
    ) {
        self.bundle = bundle
        self.fileManager = fileManager
        self.extraRoots = extraRoots
    }

    func token(forProvider providerID: String) -> String? {
        let name = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        for root in searchRoots() {
            for candidate in tokenFileCandidates(providerID: name, root: root) {
                if let token = readTokenFile(candidate) {
                    return token
                }
            }
        }
        return nil
    }

    private func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL.appendingPathComponent(Self.directoryName, isDirectory: true))
        }
        roots.append(contentsOf: extraRoots)
        roots.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources/\(Self.directoryName)", isDirectory: true)
        )
        roots.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(Self.directoryName)", isDirectory: true)
        )

        var seen: Set<String> = []
        return roots.filter { root in
            let path = root.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private func tokenFileCandidates(providerID: String, root: URL) -> [URL] {
        [
            root.appendingPathComponent("\(providerID).token", isDirectory: false),
            root.appendingPathComponent("\(providerID).txt", isDirectory: false)
        ]
    }

    private func readTokenFile(_ url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
