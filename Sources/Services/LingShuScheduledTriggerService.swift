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
    var lastFiredAt: Date?

    var scheduleText: String {
        String(format: "%@ %02d:%02d", repeatsDaily ? "每天" : "一次", hour, minute)
    }
}

/// 定时触发服务：分钟级检查，JSON 持久化在本机。模块独立、可整体替换。
@MainActor
final class LingShuScheduledTriggerService: ObservableObject {
    @Published private(set) var triggers: [LingShuScheduledTrigger] = []

    private let storeURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingShu/Triggers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("triggers.json")
        load()
    }

    func add(title: String, prompt: String, hour: Int, minute: Int, repeatsDaily: Bool) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, (0...23).contains(hour), (0...59).contains(minute) else { return }
        triggers.append(.init(
            title: trimmedTitle.isEmpty ? String(trimmedPrompt.prefix(18)) : trimmedTitle,
            prompt: trimmedPrompt,
            hour: hour,
            minute: minute,
            repeatsDaily: repeatsDaily
        ))
        save()
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

    /// 每分钟调用：返回此刻到点的触发器并打点（同一分钟防重复，一次性触发后停用）。
    func fireDueTriggers(now: Date = Date(), calendar: Calendar = .current) -> [LingShuScheduledTrigger] {
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        var fired: [LingShuScheduledTrigger] = []

        for index in triggers.indices {
            let trigger = triggers[index]
            guard trigger.enabled, trigger.hour == hour, trigger.minute == minute else { continue }
            if let lastFiredAt = trigger.lastFiredAt,
               calendar.isDate(lastFiredAt, equalTo: now, toGranularity: .minute) {
                continue
            }
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
    static func setLaunchAtLogin(_ enabled: Bool) -> String {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                return "已设置开机自启。"
            } else {
                try SMAppService.mainApp.unregister()
                return "已取消开机自启。"
            }
        } catch {
            return "开机自启设置失败：\(error.localizedDescription)"
        }
    }
}
