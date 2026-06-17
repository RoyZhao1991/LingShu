import Foundation

/// 提示词上下文组装：记忆提示 + 实时态势感知 + 情境上下文。
/// 从 LingShuState 主文件拆出，守住单文件聚焦。
@MainActor
extension LingShuState {
    /// 有有效感知信号时注入对话上下文；情境上下文（时间/时段/连续使用时长/后台任务）常驻注入。
    /// 怎么用这些情境（深夜提醒休息、结合环境打趣）由模型自行判断，不写死策略。
    func composedPromptHint(baseMemory: String) -> String {
        var hint = mainThreadKernel.promptHint(baseMemory: baseMemory)
        if let perception = livePerceptionContextProvider?(),
           !perception.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hint += "\n实时态势感知（来自麦克风/摄像头，已通过感知网关解析）：\n\(perception)"
        }
        hint += "\n" + LingShuSituationContext.compose(.init(
            sessionStartedAt: sessionStartedAt,
            activeTaskTitle: isModelExecuting ? activeTaskThread.map { String($0.prompt.prefix(40)) } : nil,
            activeTaskStage: isModelExecuting ? "\(missionTitle)，已进行 \(formatElapsed(executionElapsedSeconds))" : nil,
            externalSensoryLine: externalSensory.situationContribution()
        ))
        return hint
    }
}
