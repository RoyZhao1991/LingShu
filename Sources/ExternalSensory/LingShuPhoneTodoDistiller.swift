import Foundation

/// 通知/读数 → **关键待办** 蒸馏（方案 §4 第 3 步，M3）。**与数据源无关**：ANCS、EventKit、
/// 未来的短信库读数都喂同一套。
///
/// 分两条路：
/// - `heuristicDistill`：纯函数、确定性、离线可跑（降噪去重 + 规则成待办），单测覆盖；也是
///   断网/无大脑时的兜底。
/// - 模型驱动蒸馏：在 `LingShuState+ExternalSensory` 里用大脑会话做（"只挑真需行动的，忽略寒暄/
///   系统噪声"），失败回退到本 heuristic。
enum LingShuPhoneTodoDistiller {
    /// 降噪：丢掉显著度 0（营销/娱乐）的读数，按 UID/headline 去重，保留最近窗口。
    static func denoise(_ readings: [LingShuExternalSensoryReading], now: Date = Date(), window: TimeInterval = 24 * 3600) -> [LingShuExternalSensoryReading] {
        var seen = Set<String>()
        return readings
            .filter { $0.salience >= 1 }
            .filter { now.timeIntervalSince($0.timestamp) <= window || $0.timestamp > now }
            .filter { reading in
                let key = reading.metadata["uid"].map { "\(reading.sourceID)#\($0)" } ?? "\(reading.sourceID)#\(reading.headline)"
                return seen.insert(key).inserted
            }
            .sorted { $0.salience != $1.salience ? $0.salience > $1.salience : $0.timestamp > $1.timestamp }
    }

    /// 纯启发式蒸馏：把降噪后的读数直接转成待办（不调模型）。保守——只对显著度 ≥2 的成待办。
    static func heuristicDistill(_ readings: [LingShuExternalSensoryReading], now: Date = Date()) -> [LingShuPhoneTodo] {
        denoise(readings, now: now)
            .filter { $0.salience >= 2 }
            .map { reading in
                LingShuPhoneTodo(
                    title: reading.headline,
                    sourceApp: reading.originApp ?? reading.channel.label,
                    due: reading.metadata["due"],
                    people: [],
                    actionSuggestion: defaultActionSuggestion(for: reading),
                    sourceQuote: reading.detail ?? reading.headline
                )
            }
    }

    private static func defaultActionSuggestion(for reading: LingShuExternalSensoryReading) -> String {
        switch reading.category?.lowercased() {
        case "schedule": "确认日程并预备相关资料"
        case "incomingcall", "missedcall": "尽快回电"
        case "email": "查看邮件并决定是否回复"
        case "social": "查看消息，判断是否需要回复"
        default: "查看并判断是否需要跟进"
        }
    }

    /// 给模型蒸馏用的批量提示文本（读数列表 → 一段紧凑清单）。最小必要文本、去原始正文里的多余空白。
    static func promptPayload(for readings: [LingShuExternalSensoryReading], now: Date = Date(), limit: Int = 30) -> String {
        let items = denoise(readings, now: now).prefix(limit).enumerated().map { index, reading -> String in
            var line = "\(index + 1). [\(reading.originApp ?? reading.channel.label)]"
            if let category = reading.category { line += "(\(category))" }
            line += " \(reading.headline)"
            if let detail = reading.detail, !detail.isEmpty {
                let compact = detail.replacingOccurrences(of: "\n", with: " ").prefix(160)
                line += " — \(compact)"
            }
            return line
        }
        return items.joined(separator: "\n")
    }

    /// 把所有待办压成一句给大脑的注入摘要（汇聚阶段用，紧凑、不灌全文）。
    static func situationSummary(todos: [LingShuPhoneTodo], maxItems: Int = 5) -> String? {
        guard !todos.isEmpty else { return nil }
        let head = todos.prefix(maxItems).map { todo -> String in
            let due = todo.due.map { "（\($0)）" } ?? ""
            return "・\(todo.title)\(due)"
        }.joined(separator: "\n")
        let more = todos.count > maxItems ? "\n…等共 \(todos.count) 条" : ""
        return "外接设备感知 · 关键待办：\n\(head)\(more)"
    }
}
