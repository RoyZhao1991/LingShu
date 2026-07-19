import Foundation
import ServiceManagement

/// 定时触发器：到点把指令交给灵枢主线程正常处理——内容是提醒就开口提醒，
/// 是任务就走完整协同管线（例行任务）。
struct LingShuScheduledTrigger: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var prompt: String
    var hour: Int
    var minute: Int
    /// false = 一次性，触发后自动停用。
    var repeatsDaily: Bool
    var enabled: Bool = true
    /// 最早允许触发的时间点（一次性/相对延时/指定日期用：在此之前即使到了 hour:minute 也不触发）。
    /// nil = 无下界（典型用于纯每日重复）。Optional → 旧 triggers.json 缺该键时 decodeIfPresent 自动得 nil，向后兼容。
    var fireAfter: Date?
    var lastFiredAt: Date?

    var scheduleText: String {
        if let fireAfter, !repeatsDaily {
            let f = DateFormatter()
            f.dateFormat = "M月d日 HH:mm"
            return "一次 " + f.string(from: fireAfter)
        }
        return String(format: "%@ %02d:%02d", repeatsDaily ? "每天" : "一次", hour, minute)
    }
}

/// 定时触发服务：分钟级检查，JSON 持久化在本机。模块独立、可整体替换。
@MainActor
final class LingShuScheduledTriggerService: ObservableObject {
    @Published private(set) var triggers: [LingShuScheduledTrigger] = []

    private let storeURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? LingShuRuntimeEnvironment.homeDirectory
            .appendingPathComponent("Library/Application Support/LingShu/Triggers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("triggers.json")
        load()
    }

    @discardableResult
    func add(title: String, prompt: String, hour: Int, minute: Int, repeatsDaily: Bool, fireAfter: Date? = nil) -> LingShuScheduledTrigger? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let trigger = LingShuScheduledTrigger(
            title: trimmedTitle.isEmpty ? String(trimmedPrompt.prefix(18)) : trimmedTitle,
            prompt: trimmedPrompt,
            hour: hour,
            minute: minute,
            repeatsDaily: repeatsDaily,
            fireAfter: fireAfter
        )
        triggers.append(trigger)
        save()
        return trigger
    }

    func remove(id: String) {
        triggers.removeAll { $0.id == id }
        save()
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else { return }
        triggers[index].enabled = enabled
        save()
    }

    /// 默认追赶窗口：定时器被后台暂停/短暂休眠错过了那一精确分钟，也能在窗口内补触发；
    /// 过期太久（如关机一整天后开机）则不再补，避免「上午 9 点的提醒」在晚上离谱地弹出来。
    static let defaultCatchUpWindow: TimeInterval = 3600   // 1 小时

    /// 周期调用（UI 心跳 + 后台安全的自主驱动 Task 都会调）：返回此刻**到点（含被错过后补触发）**的触发器并打点。
    /// 关键修复：旧实现要求 `now` 的分钟**精确等于** hour:minute 才触发——而驱动它的 UI 定时器在窗口遮挡/后台时会被系统
    /// 暂停（与周期感知被迁出 UI 定时器同因），导致到点那一分钟没人 tick → 永久错过。现改为「到点即触发 + 有界追赶 + 当次去重」，
    /// 对任何 tick 不规律（后台暂停、短暂休眠、tick 抖动）都健壮。
    func fireDueTriggers(now: Date = Date(), calendar: Calendar = .current,
                         catchUpWindow: TimeInterval = LingShuScheduledTriggerService.defaultCatchUpWindow) -> [LingShuScheduledTrigger] {
        var fired: [LingShuScheduledTrigger] = []

        for index in triggers.indices {
            let trigger = triggers[index]
            guard trigger.enabled else { continue }
            // ① 最早允许触发时间（一次性/相对/指定日期）：未到下界先跳过。
            if let fireAfter = trigger.fireAfter, now < fireAfter { continue }
            // ② 当天该时刻是否已到（含已过）。
            guard let scheduledToday = calendar.date(bySettingHour: trigger.hour, minute: trigger.minute, second: 0, of: now),
                  now >= scheduledToday else { continue }
            // ③ 有界追赶：错过那一分钟也补触发，但过期超过窗口则不补。
            guard now.timeIntervalSince(scheduledToday) <= catchUpWindow else { continue }
            // ④ 当次去重：本次「当天到点」已触发过（lastFiredAt 落在本次 scheduledToday 之后）则跳过。
            if let lastFiredAt = trigger.lastFiredAt, lastFiredAt >= scheduledToday { continue }
            triggers[index].lastFiredAt = now
            if !trigger.repeatsDaily {
                triggers[index].enabled = false
            }
            fired.append(triggers[index])
        }
        if !fired.isEmpty {
            save()
        }
        return fired
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([LingShuScheduledTrigger].self, from: data) else { return }
        triggers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(triggers) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

/// 常驻能力：开机自启（SMAppService）。菜单栏常驻与"关窗不退出"在 App 层实现。
enum LingShuResidencyService {
    static var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setLaunchAtLogin(
        _ enabled: Bool,
        language: LingShuVoiceLanguage = LingShuLanguagePreferenceStore.currentLanguage()
    ) -> String {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                return language == .english ? "Launch at Login is enabled." : "已设置开机自启。"
            } else {
                try SMAppService.mainApp.unregister()
                return language == .english ? "Launch at Login is disabled." : "已取消开机自启。"
            }
        } catch {
            return language == .english
                ? "Could not update Launch at Login: \(error.localizedDescription)"
                : "开机自启设置失败：\(error.localizedDescription)"
        }
    }
}
