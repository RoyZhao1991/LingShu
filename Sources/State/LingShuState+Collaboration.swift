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
            appendTrace(kind: .system, actor: "定时触发", title: "到点执行", detail: "\(trigger.scheduleText)「\(trigger.title)」已触发，交给灵枢处理。")
            chatMessages.append(.init(speaker: "灵枢", text: "⏰ 定时任务到点：\(trigger.title)，我现在处理。", isUser: false))
            _ = submitTextInput(trigger.prompt, source: .plugin("定时触发"), appendUserMessage: false)
        }
    }
}
