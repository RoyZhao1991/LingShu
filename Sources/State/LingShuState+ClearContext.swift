import Foundation

@MainActor
extension LingShuState {
    /// 清空主对话上下文(开启新会话):停掉在飞回合 → 丢弃常驻 agent 会话(下回合自动重建,
    /// 跨会话**长期记忆仍会重新 seed**)→ 聊天与执行轨迹回到初始问候/待机态。
    /// **不动任务线程与执行记录**——那是独立的「线程」历史,不属于当前对话上下文。
    /// 返回清空前是否存在常驻会话(供 MCP 命令/调用方回报)。
    @discardableResult
    func clearMainContext() -> Bool {
        let hadSession = mainAgentSessionHolder != nil
        if hasActiveModelCall { cancelCurrentCall() }   // 别把上下文从正在跑的回合下抽走:先停在飞回合
        mainAgentSessionHolder = nil                    // 懒重建:下回合起干净会话(仍走 seededDistilledMemory 注入长期记忆)
        currentAgentTurnRecordID = nil
        chatMessages = [
            .init(
                speaker: appName,
                text: LingShuLanguagePreferenceStore.initialGreeting(for: language),
                isUser: false
            )
        ]
        executionTrace = [
            .init(
                timestamp: Date(),
                kind: .system,
                actor: appName,
                title: loc("待机", "Idle"),
                detail: loc(
                    "主对话就绪。下达任务后，这里会显示路由、模型调用、agent 入队和工具输出。",
                    "Main chat is ready. Routing, model calls, agent dispatch, and tool output will appear here after you send a task."
                ),
                isStream: false
            )
        ]
        missionTitle = "待机中"
        logEvent("现在  用户清空了主对话上下文(新会话);任务线程与执行记录保留。")
        return hadSession
    }
}
