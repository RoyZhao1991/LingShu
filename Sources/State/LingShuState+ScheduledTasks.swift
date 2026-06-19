import Foundation

/// 定时调度（四肢）：让大脑能**自己**把"到点要做的事"挂成定时任务——不再因为没有工具而即兴伪造
/// launchd plist 谎称"已设置自动运行"（实测过的假象）。与 `watch_until`（条件守候）并列：
/// - `watch_until` = 等一个**外部条件满足**就续跑（轮询检查命令）。
/// - `schedule_task` = 到一个**时间点**就把指令交给灵枢正常处理（提醒就开口、任务就动手，走完整 agent 循环）。
/// 底座是既有 `LingShuScheduledTriggerService`（JSON 持久化跨重启 + 后台安全的驱动），本扩展只做"工具形态适配"，
/// 不掺业务判断（符合"加新能力=加一条工具，不写硬编码控制器"）。
@MainActor
extension LingShuState {

    func scheduledTaskTools() -> [LingShuAgentTool] {
        [scheduleTaskTool(), listScheduledTasksTool(), cancelScheduledTaskTool()]
    }

    /// 纯函数（可单测）：把"一次性、无指定日期"的 hour:minute 解析成**下一次**该时刻（今天若还没到则今天，否则明天）。
    nonisolated static func nextOccurrence(hour: Int, minute: Int, from now: Date, calendar: Calendar = .current) -> Date {
        if let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now), today > now {
            return today
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) ?? now.addingTimeInterval(86_400)
    }

    /// 纯函数（可单测）：把可选的 "YYYY-MM-DD" 指定日期 + hour:minute 解析成精确触发时间点；解析不出返回 nil。
    nonisolated static func scheduledFireAfter(dateString: String?, hour: Int, minute: Int,
                                               now: Date, calendar: Calendar = .current, repeatsDaily: Bool) -> Date? {
        // 每日重复无下界。
        if repeatsDaily { return nil }
        // 指定了具体日期 → 那天的 hour:minute。
        if let raw = dateString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let day = f.date(from: raw),
               let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
                return fire
            }
        }
        // 一次性、无日期 → 下一次该时刻（不会立刻在过去的今天误触发）。
        return nextOccurrence(hour: hour, minute: minute, from: now, calendar: calendar)
    }

    private func scheduleTaskTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "schedule_task",
            description: "把一件事挂成**定时任务**：到指定时间点我会自动把它当成新指令正常处理——是提醒就开口提醒，是任务就动手做完（走完整能力）。用于'每天早上9点提醒我看日历'、'明天下午3点帮我汇总今天的进展'、'30分钟后叫我休息'这类。需要的是**时间点**触发；若是等某个外部条件满足再继续，用 watch_until。注意：你自己用 get_current_time 确认当前时间后再换算出 hour/minute（24小时制）。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"简短标题，如'查看日历'\"},\"prompt\":{\"type\":\"string\",\"description\":\"到点时交给我的**完整指令**（我会照它正常处理）。写清要做什么，如'查看今天的日历安排并念给我听'\"},\"hour\":{\"type\":\"number\",\"description\":\"触发的小时(0-23，24小时制)\"},\"minute\":{\"type\":\"number\",\"description\":\"触发的分钟(0-59)\"},\"repeats_daily\":{\"type\":\"boolean\",\"description\":\"true=每天重复；false=只一次。默认 false\"},\"date\":{\"type\":\"string\",\"description\":\"(可选)只一次且指定某天时填 'YYYY-MM-DD'；不填则取下一次该时刻\"}},\"required\":[\"title\",\"prompt\",\"hour\",\"minute\"]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            let args = Self.parseArgs(argsJSON)
            let title = (args["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = (args["prompt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return "schedule_task 需要 prompt（到点要做的事）。" }
            guard let hour = Self.intArg(args["hour"]), (0...23).contains(hour) else { return "hour 需在 0-23（24小时制）。" }
            guard let minute = Self.intArg(args["minute"]), (0...59).contains(minute) else { return "minute 需在 0-59。" }
            let repeatsDaily = Self.boolArg(args["repeats_daily"])
            let dateStr = args["date"]
            return await MainActor.run {
                let now = Date()
                let fireAfter = Self.scheduledFireAfter(dateString: dateStr, hour: hour, minute: minute, now: now, repeatsDaily: repeatsDaily)
                guard let trigger = self.scheduledTriggers.add(title: title, prompt: prompt, hour: hour, minute: minute, repeatsDaily: repeatsDaily, fireAfter: fireAfter) else {
                    return "定时任务创建失败（参数无效）。"
                }
                self.appendTrace(kind: .runtime, actor: "定时调度", title: "已挂起：\(trigger.title)", detail: "\(trigger.scheduleText)｜到点执行：\(String(prompt.prefix(40)))")
                let when = repeatsDaily
                    ? String(format: "每天 %02d:%02d", hour, minute)
                    : (fireAfter.map { Self.formatTriggerTime($0) } ?? String(format: "%02d:%02d", hour, minute))
                return "已设置定时任务「\(trigger.title)」(\(when))。到点我会自动执行：\(String(prompt.prefix(60)))。它已持久化保存，关窗/重启都在；这是真正接入我调度系统的任务（不是写个文件假装），可用 list_scheduled_tasks 查看、cancel_scheduled_task 取消。"
            }
        }
    }

    private func listScheduledTasksTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "list_scheduled_tasks",
            description: "列出当前已设置的定时任务（什么时候触发、到点做什么）。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            await MainActor.run {
                guard let self else { return "执行环境不可用" }
                let active = self.scheduledTriggers.triggers.filter(\.enabled)
                guard !active.isEmpty else { return "当前没有已启用的定时任务。" }
                return "定时任务：\n" + active.map { "- [\($0.id.prefix(8))] \($0.scheduleText)「\($0.title)」→ \(String($0.prompt.prefix(40)))" }.joined(separator: "\n")
            }
        }
    }

    private func cancelScheduledTaskTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "cancel_scheduled_task",
            description: "取消一个定时任务（传 id 或标题）。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"任务的 id（或前缀）或标题\"}},\"required\":[\"id\"]}"
        ) { [weak self] argsJSON in
            let key = (Self.jsonField(argsJSON, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return await MainActor.run {
                guard let self else { return "执行环境不可用" }
                guard !key.isEmpty else { return "请提供要取消的任务 id 或标题。" }
                guard let target = self.scheduledTriggers.triggers.first(where: { $0.id == key || $0.id.hasPrefix(key) || $0.title == key }) else {
                    return "没找到该定时任务：\(key)"
                }
                self.scheduledTriggers.remove(id: target.id)
                return "已取消定时任务「\(target.title)」。"
            }
        }
    }

    nonisolated static func formatTriggerTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    /// 容错把工具入参（可能是 "9" 或 "9.0" 或前后空白）解析成 Int。
    nonisolated static func intArg(_ raw: String?) -> Int? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let i = Int(s) { return i }
        if let d = Double(s) { return Int(d) }
        return nil
    }

    /// 容错布尔：JSONSerialization 的布尔经 `String(describing:)` 可能成 "1"/"0"，也可能是 "true"/"false"。
    nonisolated static func boolArg(_ raw: String?) -> Bool {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return s == "true" || s == "1" || s == "yes"
    }
}
