import Foundation

/// Lightweight diagnostics for the compose/input refresh chain.
///
/// Toggle with:
/// `defaults write com.zhaoroy.LingShu lingshu.debug.inputRender -bool true`
final class LingShuInputRenderDiagnostics: @unchecked Sendable {
    static let shared = LingShuInputRenderDiagnostics()

    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var lastLogAt: [String: Date] = [:]

    private init() {}

    private static var isEnabled: Bool {
        let defaults = LingShuRuntimeEnvironment.preferences
        guard defaults.object(forKey: "lingshu.debug.inputRender") != nil else { return false }
        return defaults.bool(forKey: "lingshu.debug.inputRender")
    }

    @discardableResult
    static func log(_ key: String, _ message: String, minInterval: TimeInterval = 0) -> Int {
        shared.log(key, message, minInterval: minInterval)
    }

    private func log(_ key: String, _ message: String, minInterval: TimeInterval) -> Int {
        guard Self.isEnabled else { return 0 }

        let now = Date()
        var count = 0
        var shouldWrite = false

        lock.lock()
        count = (counters[key] ?? 0) + 1
        counters[key] = count
        let previous = lastLogAt[key] ?? .distantPast
        if minInterval <= 0 || now.timeIntervalSince(previous) >= minInterval {
            lastLogAt[key] = now
            shouldWrite = true
        }
        lock.unlock()

        if shouldWrite {
            lingShuControlLog("input-render[\(key)#\(count)] \(message)")
        }
        return count
    }
}
