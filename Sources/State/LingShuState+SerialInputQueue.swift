import Foundation

/// **串行输入队列**(用户定调 2026-06-25「砍掉双线并行」)。
///
/// 背景:此前是「1 任务 + 1 会话」双线并行——任务线(派发的隔离子线程)与问答线(主会话)可同时跑。
/// 问题:两条不同上下文同时在跑,模型运行时容易把对方的上下文当成当前上下文 → 上下文污染。
///
/// 新约束(单串行):**任一回合(问答 OR 任务子线程)在真跑时,所有新顶层输入进这条队列排队**;
/// 当前回合完全返回(问答线 `executeMainTurn` 收尾 / 任务线 `promoteQueuedDispatchIfPossible`)后,**逐条出队**重新提交。
/// 同一时刻只有一个上下文在跑,模型更容易认对当前上下文。
///
/// 放行(不入队,在 `submitTextInput` 闸门之前已各自处理):演示/录制实时交互、声明式调用、自主运行答复/控制、
/// 在岗喂入、对"已有记录"的显式续接、本机即时直答(无模型调用、无污染)。
struct LingShuPendingSerialInput: Identifiable, Equatable {
    let id: String
    let prompt: String
    let visiblePrompt: String
    let source: LingShuDialogueInputSource
    let attachmentNames: [String]
    let attachmentPaths: [String]
    /// 入队时紧跟用户消息放的"已排队"气泡;出队执行时复用它显示进度/结果(保持聊天流一问一答)。
    let bubbleID: UUID
    let createdAt: Date

    init(
        prompt: String,
        visiblePrompt: String? = nil,
        source: LingShuDialogueInputSource,
        bubbleID: UUID,
        attachmentNames: [String] = [],
        attachmentPaths: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = "serial-\(UUID().uuidString.prefix(8))"
        self.prompt = prompt
        self.visiblePrompt = (visiblePrompt ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.attachmentNames = attachmentNames
        self.attachmentPaths = attachmentPaths
        self.bubbleID = bubbleID
        self.createdAt = createdAt
    }

    static func == (a: LingShuPendingSerialInput, b: LingShuPendingSerialInput) -> Bool { a.id == b.id }
}

@MainActor
extension LingShuState {

    /// 当前是否有回合在**真跑**(问答线在飞 / 问答 worker 在跑 / 任务子线程在执行)。
    /// 注意:`waitingForUser`(等用户回答)的派发任务已被 `pruneInactiveDispatchedTaskBubbles` 从活跃集剔除,
    /// 因此**不**算"在跑"——此时用户输入应作为答复喂回那条线程,不入队(那会死锁)。
    func currentlyExecutingTurn() -> Bool {
        if !sharedKernelActiveThreadIDs.isEmpty { return true }
        if hasActiveModelCall { return true }            // isModelReplying / isModelExecuting
        if executingChatTurnID != nil { return true }    // 问答线当前在跑的那条
        if activeAgentTurnTask != nil { return true }    // 问答 worker 在跑(executingChatTurnID 可能尚未同步置)
        if !pendingChatTurnIDs.isEmpty { return true }   // 问答线还有未跑完的(理论上被闸门拦,兜底)
        pruneInactiveDispatchedTaskBubbles()             // 清掉 waiting/终态的残留映射
        return !activeTaskThreadRecordIDs.isEmpty        // 任务子线程在执行(与主对话气泡解耦)
    }

    /// 有回合在跑 → 把这条新输入放进串行队列,显示"已排队"气泡,等当前回合完全返回后自动接着处理。
    func enqueueSerialInput(
        prompt: String,
        source: LingShuDialogueInputSource,
        visiblePrompt: String? = nil,
        attachmentNames: [String] = [],
        attachmentPaths: [String] = []
    ) {
        let bubble = ChatMessage(
            speaker: "灵枢",
            text: "📥 已排队(前面还有一件事在跑,完成后我自动接着处理这条;排队中你可在队列区删掉它)。",
            isUser: false
        )
        chatMessages.append(bubble)
        pendingSerialInputs.append(.init(
            prompt: prompt,
            visiblePrompt: visiblePrompt,
            source: source,
            bubbleID: bubble.id,
            attachmentNames: attachmentNames,
            attachmentPaths: attachmentPaths
        ))
        appendTrace(kind: .route, actor: "输入队列", title: "串行入队",
                    detail: "有回合在跑,本条排队等它完全返回(单串行,不并行污染上下文):\(String((visiblePrompt ?? prompt).prefix(36)))")
    }

    /// 当前回合完全返回、系统空闲 → 出队**最早一条**,复用其"已排队"气泡重新提交走正常分诊。
    /// 一次只出一条:出队后若它又起了新回合(问答/任务),后续仍排队,等它收尾再出下一条 → 严格串行。
    func drainSerialInputsIfIdle() {
        guard !pendingSerialInputs.isEmpty else { return }
        guard !currentlyExecutingTurn() else { return }
        let next = pendingSerialInputs.removeFirst()
        appendTrace(kind: .route, actor: "输入队列", title: "出队处理",
                    detail: "上一件事已完全返回,接着处理排队的这条:\(String(next.visiblePrompt.prefix(36)))")
        // 用户消息入队时已显示,这里不重复 append;复用"已排队"气泡承载本轮进度/结果。
        _ = submitTextInput(
            next.prompt,
            source: next.source,
            appendUserMessage: false,
            reusePlaceholderID: next.bubbleID,
            visibleUserText: next.visiblePrompt,
            attachmentNames: next.attachmentNames,
            attachmentPaths: next.attachmentPaths
        )
    }

    /// 用户在队列区删除一条尚未出队的排队输入。
    func removeSerialInput(id: String) {
        guard let idx = pendingSerialInputs.firstIndex(where: { $0.id == id }) else { return }
        let removed = pendingSerialInputs.remove(at: idx)
        appendTrace(kind: .route, actor: "输入队列", title: "已从队列区删除", detail: String(removed.prompt.prefix(36)))
        if let bIdx = chatMessages.firstIndex(where: { $0.id == removed.bubbleID }) {
            chatMessages[bIdx].text = "已从队列区移除。"
            chatMessages[bIdx].isLoading = false
        }
    }
}
