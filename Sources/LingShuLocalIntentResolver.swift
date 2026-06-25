import Foundation

struct LingShuLocalIntentResolver {
    static func answer(
        for prompt: String,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "zh_Hans_CN")
    ) -> String? {
        let normalized = normalize(prompt)
        guard !normalized.isEmpty else { return nil }

        if isTimeQuestion(normalized) {
            return "现在是 \(format(now, pattern: "HH:mm", timeZone: timeZone, locale: locale))。"
        }

        if isDateQuestion(normalized) {
            let date = format(now, pattern: "yyyy年M月d日", timeZone: timeZone, locale: locale)
            let weekday = format(now, pattern: "EEEE", timeZone: timeZone, locale: locale)
            let time = format(now, pattern: "HH:mm", timeZone: timeZone, locale: locale)
            return "今天是 \(date)，\(weekday)，现在 \(time)。"
        }

        // **身份/能力问题不再走本机罐头**(用户定调 2026-06-25:要 AGI 真答,不要关键词模板垃圾)——
        // 「你是谁/介绍自己/能做什么」一律交给大脑结合身份 seed + 真实能力动态回答。这里只保留**事实型**即时快答(时间/日期)。
        return nil
    }

    private static func isTimeQuestion(_ normalized: String) -> Bool {
        let signals = [
            "现在几点", "现在几点了", "几点了", "几点钟", "现在时间", "当前时间",
            "时间是多少", "现在几时", "what time", "current time"
        ]
        return signals.contains { normalized.contains($0) }
    }

    private static func isDateQuestion(_ normalized: String) -> Bool {
        let signals = [
            "今天几号", "今天日期", "现在日期", "今天星期几", "今天周几",
            "现在几号", "几月几日", "现在是几月几日", "今天是几月几日",
            "星期几", "周几", "current date", "what date"
        ]
        return signals.contains { normalized.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private static func format(
        _ date: Date,
        pattern: String,
        timeZone: TimeZone,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
