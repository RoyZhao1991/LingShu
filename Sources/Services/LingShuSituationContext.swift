import Foundation

/// 单个态势组件：负责一类情境信号（时间、连续使用、说话人、视觉、后台任务…）。
/// 能贡献就返回一句事实，不适用返回 nil。**新增态势维度（环境异常、位置、设备状态、
/// 着火/跌倒一类安全信号…）只要写一个组件加进装配清单即可，不必动 compose。**
/// 注意：组件只供给**事实**，怎么用（深夜提醒休息、着火该不该报警）交给大模型综合评判，
/// 这里不写死任何策略、也不替模型把态势"输出"成结论。
protocol LingShuSituationComponent: Sendable {
    func contribute(_ inputs: LingShuSituationContext.Inputs) -> String?
}

/// 情境上下文引擎：把各态势组件的事实拼成一段紧凑的【当前情境】注入模型提示。
///
/// 分层：摄像头在线且云感知路由可用时，场景与人物状态来自云视觉模型
/// （经感知网关的实时态势块注入，对话时按需刷新）；这里的"连续使用时长+时段"
/// 只是摄像头关闭时的兜底信号，不是精神状态的主判据。
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

    /// 默认装配清单（顺序即拼接顺序）：时间 → 连续使用 → 说话人 → 视觉 → 后台任务。
    static let defaultComponents: [LingShuSituationComponent] = [
        TimeComponent(),
        SessionDurationComponent(),
        SpeakerComponent(),
        VisionComponent(),
        TaskProgressComponent()
    ]

    /// 组件拼装：逐个收集能贡献的事实，拼成【当前情境】。可传入自定义组件清单（扩展/测试）。
    static func compose(_ inputs: Inputs, components: [LingShuSituationComponent] = defaultComponents) -> String {
        let lines = components.compactMap { $0.contribute(inputs) }
        return "【当前情境】" + lines.joined(separator: " ")
    }

    // MARK: - 内建态势组件

    struct TimeComponent: LingShuSituationComponent {
        func contribute(_ inputs: Inputs) -> String? {
            let hour = inputs.calendar.component(.hour, from: inputs.now)
            let minute = inputs.calendar.component(.minute, from: inputs.now)
            return String(format: "本机时间 %02d:%02d（%@）。", hour, minute, daySegment(hour: hour))
        }
    }

    struct SessionDurationComponent: LingShuSituationComponent {
        func contribute(_ inputs: Inputs) -> String? {
            guard let startedAt = inputs.sessionStartedAt else { return nil }
            let minutes = Int(inputs.now.timeIntervalSince(startedAt) / 60)
            guard minutes >= 45 else { return nil }
            return "用户本次已连续使用约 \(durationText(minutes: minutes))。"
        }
    }

    struct SpeakerComponent: LingShuSituationComponent {
        func contribute(_ inputs: Inputs) -> String? { inputs.speakerLine }
    }

    struct VisionComponent: LingShuSituationComponent {
        func contribute(_ inputs: Inputs) -> String? {
            guard let vision = inputs.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !vision.isEmpty else {
                return nil
            }
            return "摄像头画面：\(vision)。"
        }
    }

    struct TaskProgressComponent: LingShuSituationComponent {
        func contribute(_ inputs: Inputs) -> String? {
            guard let task = inputs.activeTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
                return nil
            }
            let stage = inputs.activeTaskStage.map { "（阶段：\($0)）" } ?? ""
            return "后台有任务正在执行：\(task)\(stage)。"
        }
    }

    // MARK: - 共享格式化

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
