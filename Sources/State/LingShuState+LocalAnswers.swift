import Foundation

/// 本地直答判定：身份口径、关于灵枢自身机制的说明等"事实固定"的问题在本机直接回答。
/// 时间/寒暄等情境敏感问题不在此列——它们走直答快路，由模型结合情境上下文作答。
@MainActor
extension LingShuState {
    func mainThreadDirectAnswer(for prompt: String, memoryContext: MainThreadMemoryContext) -> String? {
        let normalized = normalizeMemoryText(prompt)

        // 时间/寒暄类不再走写死的本地秒回：直答快路足够快（首字 ~1.6s），
        // 且模型拿着情境上下文（本机时间、时段、说话人画像）能给出有温度的回应，
        // 例如深夜问"几点了"时顺带提醒休息——这由模型判断，不是写死的策略。

        let identityPrompts = ["你是谁", "你是什么", "你叫什么", "灵枢是谁"]
        if identityPrompts.contains(normalized) || (normalized.contains("你是谁") && normalized.count <= 8) {
            return "我是灵枢，有什么可以帮你的？"
        }

        let selfIdentityPrompts = ["我是谁", "你知道我是谁吗", "你知道我是谁么", "你知道我是谁", "我是什么人"]
        if selfIdentityPrompts.contains(normalized) {
            return userIdentityAnswer(from: memoryContext)
        }

        if isLingShuKnowledgeQuestion(prompt) {
            let memoryNote = memoryContext.shouldLoadHistory
                ? "\n\n我已参考主线程记忆：\(compactSummaryText(memoryContext.status, limit: 90))"
                : ""

            if normalized.contains("记忆") || normalized.contains("线程") || normalized.contains("冷备") || normalized.contains("压缩") {
                return "灵枢的记忆分两层：主线程记忆负责判断当前消息是否续接历史主题；执行记忆负责恢复具体任务线程的目标、约束、已完成事项和风险。热记忆过长或过旧时会压缩并进入冷备库，后续可以通过检索冷备重新接起。\(memoryNote)"
            }

            if normalized.contains("agent") || normalized.contains("智能体") || normalized.contains("调用链") {
                return "灵枢不会一开始展示所有 agent。主线程先判断当前任务是否需要协作；需要时才动态创建任务线程，并只在右侧调用链显示本轮真实参与的 agent。普通问答则由我基于记忆和知识库直接回应。\(memoryNote)"
            }

            if normalized.contains("能力") || normalized.contains("架构") || normalized.contains("流程") || normalized.contains("怎么工作") {
                return "灵枢的核心不是亲自做工，而是承令、判断、分派、监督和验收。主线程负责理解意图和检索记忆；任务线程负责承接需要落地的工作；内部或外部 agent 负责具体执行；最终由我统一向你交付结果。\(memoryNote)"
            }
        }

        return nil
    }

    private func userIdentityAnswer(from memoryContext: MainThreadMemoryContext) -> String {
        let memoryText = memoryContext.promptHint
        if memoryText.contains("身份") || memoryText.contains("用户") || memoryText.contains("课题") || memoryText.contains("项目") {
            return "从当前记忆看，你是正在与我协作推进任务的人。更具体的身份，我只以你明确告诉我的信息为准。"
        }

        return "我还没有足够可靠的身份记忆。现在我只知道，你是正在与我协作的人；你告诉我的身份，我会记住。"
    }

    private func isLingShuKnowledgeQuestion(_ prompt: String) -> Bool {
        let normalized = normalizeMemoryText(prompt)
        let subjectSignals = ["灵枢", "你", "agent", "智能体", "记忆", "线程", "冷备", "调用链", "能力架构", "流程"]
        return isKnowledgeOnlyQuestion(prompt)
            && subjectSignals.contains { normalized.contains($0) }
            && !isDevelopmentQueueRequest(prompt)
            && !isProjectExecutionRequest(prompt)
    }
}
