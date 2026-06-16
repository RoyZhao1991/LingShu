import Foundation
import Network

/// 网络可达性监控(断网重连自动续跑用):`NWPathMonitor` 监听链路,**不可达→可达**跳变(去抖)时回调。
///
/// 注意:NWPath「satisfied」只表示有链路,不保证网关真活——所以这里只做"触发重试"的信号,
/// **真正的探针是续跑时那一次模型调用本身**:若续跑又因不可达返回 `.interrupted`,任务会再次进入暂停,
/// 等下一次链路跳变/重试。这样既不需要单独的网关 ping 端点,又对"链路有但网关没活"自愈。
final class LingShuConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lingshu.connectivity")
    private var wasSatisfied = true
    private var debounce: DispatchWorkItem?
    private let onReconnect: @Sendable () -> Void

    /// - Parameter onReconnect: 链路从不可达恢复(去抖后)时回调。实现里应去 MainActor 续跑暂停的任务。
    init(onReconnect: @escaping @Sendable () -> Void) {
        self.onReconnect = onReconnect
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let became = satisfied && !self.wasSatisfied
            self.wasSatisfied = satisfied
            guard became else { return }
            // 去抖:链路刚恢复常抖几下,等 2s 稳定再触发自动续跑,避免反复 thrash。
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onReconnect() }
            self.debounce = work
            self.queue.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        debounce?.cancel()
        monitor.cancel()
    }
}
