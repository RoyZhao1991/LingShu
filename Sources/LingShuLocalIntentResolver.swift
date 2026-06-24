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

        if LingShuSelfReferenceIntent.isDirectAssistantSelfIntroduction(prompt) {
            return selfReferenceAnswer(for: normalized)
        }

        return nil
    }

    private static func selfReferenceAnswer(for normalized: String) -> String {
        if normalized.contains("你是谁")
            || normalized.contains("你是什么")
            || normalized.contains("你叫什么")
            || normalized.contains("灵枢是谁")
            || normalized.contains("灵枢是什么") {
            return "我是灵枢，有什么可以帮你的？"
        }

        if normalized.contains("能力") || normalized.contains("能做什么") {
            return "我是灵枢，你身边的通用智能中枢。你只管说目标，判断、分派、执行和复盘交给我。"
        }

        return "我是灵枢，一个面向真实任务的通用智能中枢。你只管说目标，剩下的判断、分派和推进交给我。"
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
