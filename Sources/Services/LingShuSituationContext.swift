import Foundation

/// 情境上下文引擎：把"现在几点、聊了多久、谁在说话、看见了什么、后台在忙什么"
/// 合成一段紧凑的情境描述注入模型提示。怎么利用情境（深夜提醒休息、对环境打趣、
/// 按说话人调整语气）完全交给模型判断——这里只供给事实，不写死任何策略。
enum LingShuSituationContext {
    struct Inputs {
        var now: Date = Date()
        var calendar: Calendar = .current
        var sessionStartedAt: Date?
        var speakerLine: String?
        var visionSummary: String?
        var activeTaskTitle: String?
        var activeTaskStage: String?
    }

    static func compose(_ inputs: Inputs) -> String {
        var lines: [String] = []

        let hour = inputs.calendar.component(.hour, from: inputs.now)
        let minute = inputs.calendar.component(.minute, from: inputs.now)
        lines.append(String(format: "本机时间 %02d:%02d（%@）。", hour, minute, daySegment(hour: hour)))

        if let startedAt = inputs.sessionStartedAt {
            let minutes = Int(inputs.now.timeIntervalSince(startedAt) / 60)
            if minutes >= 45 {
                lines.append("用户本次已连续使用约 \(durationText(minutes: minutes))。")
            }
        }

        if let speakerLine = inputs.speakerLine {
            lines.append(speakerLine)
        }

        if let vision = inputs.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !vision.isEmpty {
            lines.append("摄像头画面：\(vision)。")
        }

        if let task = inputs.activeTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            let stage = inputs.activeTaskStage.map { "（阶段：\($0)）" } ?? ""
            lines.append("后台有任务正在执行：\(task)\(stage)。")
        }

        return "【当前情境】" + lines.joined(separator: " ")
    }

    static func daySegment(hour: Int) -> String {
        switch hour {
        case 5..<8: "清晨"
        case 8..<12: "上午"
        case 12..<14: "中午"
        case 14..<18: "下午"
        case 18..<19: "傍晚"
        case 19..<23: "晚上"
        default: "深夜"
        }
    }

    static func durationText(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) 分钟"
        }
        let hours = Double(minutes) / 60.0
        return String(format: "%.1f 小时", hours)
    }
}
