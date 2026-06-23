import Foundation

/// 定时触发接入：到点的提醒/例行任务以插件来源进入统一 agent 循环正常处理。
/// （旧的「规划→专家→评审→验收」协同管线已随启发式前置门一并退役，见架构速查手册 §5。）
@MainActor
extension LingShuState {
    /// 定时触发：到点的提醒/例行任务以插件来源进入 agent 主入口，由模型自行决定怎么处理。
    func fireScheduledTriggersIfDue(now: Date) {
        let due = scheduledTriggers.fireDueTriggers(now: now)
        guard !due.isEmpty else { return }
        for trigger in due {
            let anchoredPrompt = Self.scheduledTriggerPrompt(trigger: trigger, firedAt: now)
            let anchor = Self.scheduledTriggerDateAnchor(firedAt: now)
            appendTrace(kind: .system, actor: "定时触发", title: "到点执行", detail: "\(trigger.scheduleText)「\(trigger.title)」已触发，触发日 \(anchor.isoDate)，交给灵枢处理。")
            chatMessages.append(.init(speaker: "灵枢", text: "⏰ 定时任务到点：\(trigger.title)，我现在处理。", isUser: false))
            _ = submitTextInput(anchoredPrompt, source: .plugin("定时触发"), appendUserMessage: false)
        }
    }

    /// 定时任务入口的时间锚点：定时任务往往包含"今天/今早/本次"等相对时间词，
    /// 必须由宿主注入本机权威触发时间，避免模型从旧记忆、旧文件名或训练先验里拿错日期。
    nonisolated static func scheduledTriggerPrompt(
        trigger: LingShuScheduledTrigger,
        firedAt: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .init(identifier: "zh_CN")
    ) -> String {
        let anchor = scheduledTriggerDateAnchor(firedAt: firedAt, timeZone: timeZone, locale: locale)
        return """
        【定时任务触发上下文】
        - 任务标题：\(trigger.title)
        - 本次触发的权威本地时间：\(anchor.dateTime)
        - ISO 日期：\(anchor.isoDate)
        - 日期戳：\(anchor.compactDate)
        - 星期：\(anchor.weekday)
        - 时区：\(anchor.timeZoneDescription)

        执行规则：
        1. 原指令里的"今天/今日/现在/早上/今晚/本次"一律以上面的权威触发时间为准。
        2. 需要生成带日期的文件名时，日期必须使用 \(anchor.compactDate)，不要沿用历史文件名里的日期。
        3. 不要从历史对话、旧任务记录、旧产物名或记忆中推断今天的日期；需要实时新闻/天气/行情时，先联网查证。

        【原定时指令】
        \(trigger.prompt)
        """
    }

    nonisolated static func scheduledTriggerDateAnchor(
        firedAt: Date,
        timeZone: TimeZone = .current,
        locale: Locale = .init(identifier: "zh_CN")
    ) -> (dateTime: String, isoDate: String, compactDate: String, weekday: String, timeZoneDescription: String) {
        let dateTime = formatScheduledTriggerDate(firedAt, pattern: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"))
        let isoDate = formatScheduledTriggerDate(firedAt, pattern: "yyyy-MM-dd", timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"))
        let compactDate = formatScheduledTriggerDate(firedAt, pattern: "yyyyMMdd", timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"))
        let weekday = formatScheduledTriggerDate(firedAt, pattern: "EEEE", timeZone: timeZone, locale: locale)
        return (dateTime, isoDate, compactDate, weekday, "\(timeZone.identifier) \(gmtOffsetString(for: timeZone, at: firedAt))")
    }

    private nonisolated static func formatScheduledTriggerDate(_ date: Date, pattern: String, timeZone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private nonisolated static func gmtOffsetString(for timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        return String(format: "GMT%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }
}
