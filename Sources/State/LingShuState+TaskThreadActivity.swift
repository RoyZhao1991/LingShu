import Foundation

private enum LingShuTaskThreadActivityStorage {
    static let unreadRecordIDsKey = "lingshu.taskThreadUnreadRecordIDs.v1"
}

@MainActor
extension LingShuState {
    var activeTaskThreadCount: Int { activeTaskThreadRecordIDs.count }
    var unreadTaskThreadCount: Int { unreadTaskThreadRecordIDs.count }

    var latestUnreadTaskThreadRecord: LingShuTaskExecutionRecord? {
        taskExecutionRecordLookup
            .filter { unreadTaskThreadRecordIDs.contains($0.id) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// 子线程开始或继续执行。只更新该记录和子线程活动投影，不触碰主会话在飞状态、
    /// 主会话占位气泡或主线程输入队列。
    func beginTaskThreadRun(recordID: String, summary: String = "子线程正在执行。") {
        guard let index = taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { return }
        let wasActive = activeTaskThreadRecordIDs.contains(recordID)
        activeTaskThreadRecordIDs.insert(recordID)
        markTaskThreadRead(recordID)

        if !wasActive || taskExecutionRecords[index].status != .running {
            taskExecutionRecords[index].taskOutcome = nil
            commitTaskThreadState(
                recordID: recordID,
                status: .running,
                phase: .executing,
                summary: summary,
                persist: true,
                trace: !wasActive
            )
        }
        publishControlSnapshot()
    }

    /// 子线程离开运行态。新结果只进入未读集合，不向正在生成的主会话插入消息。
    func endTaskThreadRun(recordID: String, notifyWhenHidden: Bool = true) {
        guard activeTaskThreadRecordIDs.remove(recordID) != nil else { return }
        let isVisible = isTaskRecordPresented && selectedTaskRecordID == recordID
        if notifyWhenHidden && !isVisible {
            unreadTaskThreadRecordIDs.insert(recordID)
            persistUnreadTaskThreadRecordIDs()
        }
        publishControlSnapshot()
    }

    func isTaskThreadUnread(_ recordID: String) -> Bool {
        unreadTaskThreadRecordIDs.contains(recordID)
    }

    func markTaskThreadRead(_ recordID: String) {
        guard unreadTaskThreadRecordIDs.remove(recordID) != nil else { return }
        persistUnreadTaskThreadRecordIDs()
    }

    func markAllTaskThreadsRead() {
        guard !unreadTaskThreadRecordIDs.isEmpty else { return }
        unreadTaskThreadRecordIDs.removeAll()
        persistUnreadTaskThreadRecordIDs()
    }

    func openLatestUnreadTaskThread() {
        guard let record = latestUnreadTaskThreadRecord else { return }
        openTaskRecord(record.id)
    }

    func restoreUnreadTaskThreadRecordIDs() {
        let stored = Set(UserDefaults.standard.stringArray(
            forKey: LingShuTaskThreadActivityStorage.unreadRecordIDsKey
        ) ?? [])
        let known = Set(taskExecutionRecordLookup.map(\.id))
        unreadTaskThreadRecordIDs = stored.intersection(known)
        persistUnreadTaskThreadRecordIDs()
    }

    private func persistUnreadTaskThreadRecordIDs() {
        UserDefaults.standard.set(
            unreadTaskThreadRecordIDs.sorted(),
            forKey: LingShuTaskThreadActivityStorage.unreadRecordIDsKey
        )
    }
}
