import Foundation
import EventKit

/// 外接感知源 · **日历 + 提醒事项**（EventKit）。
///
/// 方案 §8 的"最稳起步源"：系统级、零配对、隐私可控、立刻可用。与 ANCS 共用同一条统一
/// 感知流和同一套下游蒸馏（数据源无关）——这正是把上游做成可插拔协议的意义。
///
/// 线程模型：自己持有 `EKEventStore` 与一个私有串行队列，所有 store 访问只在该队列上发生；
/// 读数经 `AsyncStream.Continuation`（线程安全）汇聚出去。监听 `.EKEventStoreChanged` + 周期
/// 刷新（默认 5 分钟），变化即重新抓取近 48 小时窗口。
final class LingShuEventKitSensorySource: NSObject, LingShuExternalSensorySource, @unchecked Sendable {
    static let sourceID = "eventkit.calendar-reminders"

    let descriptor = LingShuExternalSensoryDescriptor(
        id: LingShuEventKitSensorySource.sourceID,
        displayName: "日历 + 提醒事项",
        englishName: "Calendar + Reminders",
        channel: .calendar,
        requiresPairing: false,
        summary: "系统级日历与提醒事项，零配对、本地只读",
        englishSummary: "System calendar & reminders, no pairing, local read-only"
    )

    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "lingshu.sensory.eventkit")
    private var continuation: AsyncStream<LingShuExternalSensorySignal>.Continuation?
    private var refreshTimer: DispatchSourceTimer?
    /// 已发出读数的去重键（事件标识符 + 末次修改），避免每次刷新重复灌入。
    private var emittedKeys = Set<String>()
    /// 抓取窗口：从现在起向后看的时长。
    private let lookAhead: TimeInterval

    init(lookAhead: TimeInterval = 48 * 3600) {
        self.lookAhead = lookAhead
        super.init()
    }

    func activate() -> AsyncStream<LingShuExternalSensorySignal> {
        AsyncStream { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                self.continuation = continuation
                self.continuation?.yield(.status(.connecting))
                self.requestAccessAndStart()
            }
            continuation.onTermination = { [weak self] _ in
                self?.teardown()
            }
        }
    }

    func deactivate() {
        queue.async { [weak self] in
            self?.continuation?.finish()
        }
    }

    // MARK: - 内部

    private func requestAccessAndStart() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await self.store.requestFullAccessToEvents()
                let reminders = try await self.store.requestFullAccessToReminders()
                self.queue.async {
                    guard events || reminders else {
                        self.continuation?.yield(.status(.unavailable("未授权访问日历/提醒事项")))
                        self.continuation?.finish()
                        return
                    }
                    self.beginObserving()
                    self.refresh()
                    self.continuation?.yield(.status(.streaming))
                }
            } catch {
                self.queue.async {
                    self.continuation?.yield(.status(.unavailable(error.localizedDescription)))
                    self.continuation?.finish()
                }
            }
        }
    }

    private func beginObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeChanged),
            name: .EKEventStoreChanged,
            object: store
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        refreshTimer = timer
    }

    @objc private func storeChanged() {
        queue.async { [weak self] in self?.refresh() }
    }

    /// 抓取近窗口内的日历事件 + 未完成提醒，归一成读数发出（已去重）。在 queue 上调用。
    private func refresh() {
        let now = Date()
        let end = now.addingTimeInterval(lookAhead)

        // 日历事件
        let calendars = store.calendars(for: .event)
        if !calendars.isEmpty {
            let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
            for event in store.events(matching: predicate) {
                emitEventIfNew(event)
            }
        }

        // 提醒事项（回调式 API）
        let reminderCalendars = store.calendars(for: .reminder)
        guard !reminderCalendars.isEmpty else { return }
        let reminderPredicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: end,
            calendars: reminderCalendars
        )
        store.fetchReminders(matching: reminderPredicate) { [weak self] reminders in
            guard let self else { return }
            let items = reminders ?? []
            self.queue.async {
                for item in items { self.emitReminderIfNew(item) }
            }
        }
    }

    private func emitEventIfNew(_ event: EKEvent) {
        let key = "evt:\(event.eventIdentifier ?? UUID().uuidString):\(event.lastModifiedDate?.timeIntervalSince1970 ?? 0)"
        guard !emittedKeys.contains(key) else { return }
        emittedKeys.insert(key)

        let start = event.startDate ?? Date()
        let due = LingShuEventKitSensorySource.dueDescription(start)
        let title = event.title ?? "（无标题日程）"
        let headline = "日历 · \(title)（\(due)）"
        let detail = [event.location, event.notes]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        continuation?.yield(.reading(LingShuExternalSensoryReading(
            channel: .calendar,
            sourceID: descriptor.id,
            timestamp: start,
            headline: headline,
            detail: detail.isEmpty ? nil : detail,
            category: "Schedule",
            originApp: "日历",
            salience: 3,
            metadata: ["kind": "event", "due": due]
        )))
    }

    private func emitReminderIfNew(_ reminder: EKReminder) {
        let key = "rem:\(reminder.calendarItemIdentifier):\(reminder.lastModifiedDate?.timeIntervalSince1970 ?? 0)"
        guard !emittedKeys.contains(key) else { return }
        emittedKeys.insert(key)

        let title = reminder.title ?? "（无标题提醒）"
        let dueDate = reminder.dueDateComponents?.date
        let due = dueDate.map { LingShuEventKitSensorySource.dueDescription($0) } ?? "无截止"
        let headline = "提醒 · \(title)（\(due)）"

        continuation?.yield(.reading(LingShuExternalSensoryReading(
            channel: .calendar,
            sourceID: descriptor.id,
            timestamp: dueDate ?? Date(),
            headline: headline,
            detail: reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            category: "Schedule",
            originApp: "提醒事项",
            salience: reminder.priority > 0 && reminder.priority <= 4 ? 3 : 2,
            metadata: ["kind": "reminder", "due": due]
        )))
    }

    private func teardown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
            NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: self.store)
            self.emittedKeys.removeAll()
            self.continuation = nil
        }
    }

    /// 把日期格式化成简短自然语言（如"今天 14:30"/"明天 09:00"/"6/20 10:00"）。
    nonisolated static func dueDescription(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "明天 \(time)" }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "M/d HH:mm"
        return dayFormatter.string(from: date)
    }
}
