import Foundation

/// 最近完成的可交付产出物——一条记录:任务标题 + 产出物主目录 + 完成说明节选(含路径与运行方式)。
/// 用途:用户随后说"运行起来 / 继续 / 改一下"时,**主线程和派发任务都能接上**(知道刚做了什么、在哪、怎么跑),
/// 而不是重新扫盘瞎猜(就是那次"超级玛丽做完了,却问我要运行哪个项目"的根因)。
struct LingShuDeliverable: Codable, Equatable, Sendable, Identifiable {
    var id: String          // = 任务记录 id
    var title: String
    var primaryDir: String?
    var summaryExcerpt: String
    var completedAt: Date
}

/// 产出物记忆子域:登记/召回最近交付物 + 注入会话上下文 + 增量落盘。
@MainActor
extension LingShuState {

    /// 启动时从增量存储恢复最近产出物到内存镜像(跨 app 重启续上"运行起来/继续")+ 启定时压缩。
    func loadDeliverablesIfNeeded() {
        guard recentDeliverables.isEmpty else { return }
        Task { @MainActor in
            let restored = await deliverableStore.all().suffix(8)
            if !restored.isEmpty, self.recentDeliverables.isEmpty {
                self.recentDeliverables = Array(restored)
            }
        }
        startMemoryCompactionTimerIfNeeded()
    }

    /// 定时 checkpoint(把碎片化 WAL 压实成快照,参考 MySQL 定时 checkpoint)——每 5 分钟一次,低频不打扰。
    func startMemoryCompactionTimerIfNeeded() {
        guard memoryCompactionTimer == nil else { return }
        memoryCompactionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.deliverableStore.compact() }
        }
    }

    /// 登记一条完成的产出物(有真实落盘文件才记;纯对话/无产出物不记)。同步进内存镜像 + 增量落盘。
    func recordDeliverable(recordID: String?, title: String, summary: String) {
        guard let recordID, let rec = taskExecutionRecords.first(where: { $0.id == recordID }) else { return }
        let files = rec.artifacts.map(\.location).filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { return }
        let entry = LingShuDeliverable(
            id: recordID,
            title: String(title.prefix(80)),
            primaryDir: Self.commonParentDir(files),
            summaryExcerpt: String(summary.prefix(400)),
            completedAt: Date()
        )
        recentDeliverables.removeAll { $0.id == recordID }
        recentDeliverables.append(entry)
        if recentDeliverables.count > 8 { recentDeliverables.removeFirst(recentDeliverables.count - 8) }
        Task { await deliverableStore.upsert(entry) }   // 增量写盘(WAL 追加)
    }

    /// 注入给会话的"最近产出物"上下文块:让"运行起来/继续/改一下/再优化"等接得上(优先用这里的路径与运行方式)。
    /// 空则返回空串(纯新会话不加噪音)。
    func recentDeliverablesContext() -> String {
        let recent = recentDeliverables.suffix(5)
        guard !recent.isEmpty else { return "" }
        let lines = recent.reversed().map { d -> String in
            let loc = d.primaryDir.map { "(目录:\($0))" } ?? ""
            return "- 「\(d.title)」\(loc):\(d.summaryExcerpt.prefix(220))"
        }
        return """
        【你最近完成的产出物——用户若说"运行起来/继续/改一下/再优化它"等,多半就指这些。优先用这里的目录与运行方式直接接着做,**别重新扫工作目录瞎猜要操作哪个**】
        \(lines.joined(separator: "\n"))
        """
    }

    /// 取多个落盘文件的最浅公共父目录(就是"项目根",用作运行/继续时的 cwd)。
    /// **防死循环铁律**:`("/" as NSString).deletingLastPathComponent` 仍返回 `"/"`(根目录自返回,不会变空),
    /// 所以当多个路径跨不同顶层根(如 `/tmp/...` 与 `/Users/...`)、公共祖先只剩 `"/"` 时,旧实现的 while 会**永真空转**
    /// (实测主线程 100% CPU 卡死,2026-06-19)。修法:每次缩短前比对 parent 是否与 common 相同(到顶=无法再缩)即终止,
    /// 跨根无公共目录则返回 nil(根 `"/"` 当 cwd 也无意义)。
    nonisolated static func commonParentDir(_ paths: [String]) -> String? {
        let dirs = paths.map { ($0 as NSString).deletingLastPathComponent }.filter { !$0.isEmpty }
        guard var common = dirs.first else { return nil }
        for d in dirs.dropFirst() {
            while !(d == common || d.hasPrefix(common + "/")) {
                let parent = (common as NSString).deletingLastPathComponent
                if parent == common {   // 已到根("/")无法再缩 → 无公共父目录,别再循环
                    common = ""
                    break
                }
                common = parent
            }
            if common.isEmpty { break }
        }
        return (common.isEmpty || common == "/") ? nil : common
    }
}
