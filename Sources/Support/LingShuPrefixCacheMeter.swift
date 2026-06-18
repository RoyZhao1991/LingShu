import Foundation

/// 前缀缓存**累计命中率**指标:把每次模型调用的(输入 token, 命中缓存 token)累加,给出会话累计命中率。
/// 用来上线后**盯着缓存有没有失效**——命中率突然掉=有东西把前缀打乱了(逐轮注入/工具集抖动),立刻看得见。
/// 线程安全(锁),进程级单例。纯计数,无副作用,可单测。
final class LingShuPrefixCacheMeter: @unchecked Sendable {
    static let shared = LingShuPrefixCacheMeter()

    private let lock = NSLock()
    private var totalPrompt = 0
    private var totalCached = 0
    private var calls = 0

    struct Snapshot: Equatable, Sendable {
        let calls: Int
        let totalPrompt: Int
        let totalCached: Int
        /// 累计命中率百分比(0~100)。
        var ratePercent: Int { totalPrompt > 0 ? Int((Double(totalCached) / Double(totalPrompt)) * 100) : 0 }
    }

    /// 记一次模型调用的用量(prompt=本轮输入 token,cached=其中命中前缀缓存的)。返回累计快照。
    @discardableResult
    func record(prompt: Int, cached: Int) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        if prompt > 0 {
            totalPrompt += prompt
            totalCached += max(0, cached)
            calls += 1
        }
        return Snapshot(calls: calls, totalPrompt: totalPrompt, totalCached: totalCached)
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(calls: calls, totalPrompt: totalPrompt, totalCached: totalCached)
    }

    /// 测试/重置用。
    func reset() {
        lock.lock(); defer { lock.unlock() }
        totalPrompt = 0; totalCached = 0; calls = 0
    }
}
