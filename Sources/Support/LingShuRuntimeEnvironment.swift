import Foundation

/// Process-wide storage and permission boundary.
///
/// Production keeps the normal macOS user domains. The clean-user smoke path is intentionally
/// opt-in and fails closed unless HOME, Core Foundation preferences, temporary files, and the
/// result file all point at the same disposable root. This makes a packaged-app launch useful as
/// release evidence without reading or mutating the maintainer's state.
enum LingShuRuntimeEnvironment {
    struct CleanUserSmokeConfiguration: Equatable, Sendable {
        let root: URL
        let resultFile: URL
        let source: String

        init(environment: [String: String]) throws {
            guard environment["LINGSHU_CLEAN_USER_SMOKE"] == "1" else {
                throw ConfigurationError.notRequested
            }
            guard let rawRoot = environment["LINGSHU_CLEAN_USER_ROOT"],
                  rawRoot.hasPrefix("/") else {
                throw ConfigurationError.missingAbsoluteRoot
            }

            let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
            guard root.lastPathComponent.hasPrefix("lingshu-clean-user-smoke.") else {
                throw ConfigurationError.unsafeRoot(root.path)
            }
            guard Self.standardizedPath(environment["HOME"]) == root.path,
                  Self.standardizedPath(environment["CFFIXED_USER_HOME"]) == root.path else {
                throw ConfigurationError.preferencesNotIsolated
            }

            let resultFile = URL(
                fileURLWithPath: environment["LINGSHU_CLEAN_USER_RESULT"]
                    ?? root.appendingPathComponent("result.json").path
            ).standardizedFileURL
            guard resultFile.path.hasPrefix(root.path + "/") else {
                throw ConfigurationError.resultOutsideRoot(resultFile.path)
            }

            self.root = root
            self.resultFile = resultFile
            self.source = environment["LINGSHU_CLEAN_USER_SOURCE"] ?? "packaged-app"
        }

        private static func standardizedPath(_ value: String?) -> String? {
            guard let value, value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
        }
    }

    enum ConfigurationError: LocalizedError, Equatable {
        case notRequested
        case missingAbsoluteRoot
        case unsafeRoot(String)
        case preferencesNotIsolated
        case resultOutsideRoot(String)

        var errorDescription: String? {
            switch self {
            case .notRequested:
                return "clean-user smoke mode was not requested"
            case .missingAbsoluteRoot:
                return "LINGSHU_CLEAN_USER_ROOT must be an absolute disposable directory"
            case .unsafeRoot(let path):
                return "clean-user smoke root is not recognizably disposable: \(path)"
            case .preferencesNotIsolated:
                return "HOME and CFFIXED_USER_HOME must both equal the clean-user smoke root"
            case .resultOutsideRoot(let path):
                return "clean-user smoke result must stay inside the disposable root: \(path)"
            }
        }
    }

    private static let processEnvironment = ProcessInfo.processInfo.environment

    static let cleanUserSmoke: CleanUserSmokeConfiguration? = {
        guard processEnvironment["LINGSHU_CLEAN_USER_SMOKE"] == "1" else { return nil }
        do {
            let configuration = try CleanUserSmokeConfiguration(environment: processEnvironment)
            try FileManager.default.createDirectory(
                at: configuration.root.appendingPathComponent("Library/Application Support", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: configuration.root.appendingPathComponent("tmp", isDirectory: true),
                withIntermediateDirectories: true
            )
            return configuration
        } catch {
            fatalError("Unsafe clean-user smoke configuration: \(error.localizedDescription)")
        }
    }()

    static var isCleanUserSmoke: Bool { cleanUserSmoke != nil }

    /// All application preferences use this accessor. CFFIXED_USER_HOME provides the filesystem
    /// isolation and the dedicated suite prevents accidental reads from the normal app domain.
    nonisolated(unsafe) static let preferences: UserDefaults = {
        guard isCleanUserSmoke else { return .standard }
        let suite = "com.zhaoroy.LingShu.clean-user-smoke.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Unable to create isolated clean-user preferences")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    static var homeDirectory: URL {
        cleanUserSmoke?.root ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func applicationSupportDirectory(using fileManager: FileManager = .default) -> URL {
        if let root = cleanUserSmoke?.root {
            return root.appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    static var temporaryDirectory: URL {
        cleanUserSmoke?.root.appendingPathComponent("tmp", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
    }

    static var temporaryDirectoryPath: String {
        let path = temporaryDirectory.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    static var allowsKeychainAccess: Bool { !isCleanUserSmoke }
    static var allowsPermissionServices: Bool { !isCleanUserSmoke }
    static var allowsBackgroundServices: Bool { !isCleanUserSmoke }

    static func isInsideCleanUserRoot(_ url: URL) -> Bool {
        guard let root = cleanUserSmoke?.root.standardizedFileURL.path else { return false }
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
}
