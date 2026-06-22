import Foundation
import EventKit

/// 本机知识·**日历源**(多源接入):索引日程/会议(标题/时间/地点/参与人/备注)→ "我跟谁约了什么""那个会几点"能找回。
/// EventKit 本地读取、零上传;需日历授权。走统一增量管线(scan→ingest)。
enum LingShuCalendarSource {
    static let pathPrefix = "calendar://"
    static func owns(_ path: String) -> Bool { path.hasPrefix(pathPrefix) }

    /// 扫描日历 → 归一成 `LingShuKnowledgeScan`(增量:用 `knownMtime` 按事件 lastModified 跳过未变)。
    static func scan(knownMtime: (String) -> Double?, pastDays: Int = 120, futureDays: Int = 120) async -> LingShuKnowledgeScan {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return .init() }
        let cals = store.calendars(for: .event)
        guard !cals.isEmpty else { return .init() }

        let now = Date()
        let start = now.addingTimeInterval(-Double(max(0, pastDays)) * 86_400)
        let end = now.addingTimeInterval(Double(max(1, futureDays)) * 86_400)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        var scan = LingShuKnowledgeScan()
        for ev in store.events(matching: predicate) {
            let id = ev.eventIdentifier ?? UUID().uuidString
            let path = pathPrefix + id
            scan.seenPaths.insert(path)
            // mtime = 事件最后修改时间(没有则用开始时间),供增量:事件没改过就跳过重索引。
            let mtime = (ev.lastModifiedDate ?? ev.startDate ?? now).timeIntervalSince1970
            if knownMtime(path) == mtime { continue }
            let when = ev.startDate.map { df.string(from: $0) } ?? ""
            let attendees = ev.attendees?.compactMap { $0.name }.filter { !$0.isEmpty }.joined(separator: "、") ?? ""
            let parts = [when, ev.location, attendees.isEmpty ? nil : "参与:\(attendees)", ev.notes]
                .compactMap { $0 }.filter { !$0.isEmpty }
            let text = "\(ev.title ?? "(无标题事件)")\n\(parts.joined(separator: " · "))"
            scan.changed.append(.init(path: path, mtime: mtime, text: text))
        }
        return scan
    }
}
