import Foundation

/// **统一 harness 配置**(完全版骨架 #2):把"按脑力自适应"的整套能力装配收口到一处,让**所有任务型会话**
/// (经典主会话 / 自主 / 派发子任务 / 嵌套 spine 与各阶段 inner)**共用同一套自适应 harness**——
/// 消除 `.classic` 与 `.nested` 的双底盘不一致,同时**完整保留并扩展脑力自适应机制**:
/// - 弱脑:全量工具 + 经典/分层压缩 + 串行/并行,脚手架兜底,把低水平脑拉到中水平;
/// - 强脑:延迟加载(薄)+ 并行 + token 分层压缩,放手让强脑无上限发挥。
///
/// 纯值类型(Sendable),可安全跨 actor 注入(给 `LingShuNestedAgentSession`)。`makeSession` 是**唯一**
/// "建一个带完整自适应 harness 的经典会话"的入口,classic 分支与 nested 内层都调它 → 单一真相、模块化、可迭代。
struct LingShuHarnessConfig: Sendable {
    var serialDispatch: Bool = false        // 工具调度:false=并行(默认)/true=串行
    var classicCompact: Bool = false        // 压缩:false=token 分层(默认)/true=经典按条数
    var tokenBudget: Int = 24_000           // token 分层压缩的预算
    var deferredCatalog: Bool = false       // 工具目录延迟加载(强脑/lean 档开;按脑力自适应)
    var factSink: (@Sendable ([String]) async -> Void)? = nil   // 压缩抽出的事实回灌知识图谱

    func dispatcher() -> any LingShuToolDispatching {
        serialDispatch ? LingShuSerialToolDispatcher() : LingShuParallelToolDispatcher()
    }

    /// 历史压缩器:仅对有上下文窗口(maxHistoryMessages>0)的常驻会话启用;短命子会话(=0)不压缩(原语义)。
    func compactor(maxHistoryMessages: Int) -> (any LingShuHistoryCompacting)? {
        guard maxHistoryMessages > 0 else { return nil }
        return classicCompact ? LingShuMessageCountCompactor(maxHistoryMessages: maxHistoryMessages)
                              : LingShuLayeredCompactor(tokenBudget: tokenBudget)
    }

    /// 按脑力档决定工具暴露:延迟加载(强脑)→ 核心集 + search_tools,新鲜暴露集;否则全暴露。
    func applyCatalog(_ tools: [LingShuAgentTool]) -> (tools: [LingShuAgentTool], exposed: LingShuExposedToolSet?) {
        guard deferredCatalog, tools.count > LingShuToolCatalog.coreToolNames.count else { return (tools, nil) }
        let built = LingShuToolCatalog.build(allTools: tools)
        return (built.tools, built.exposed)
    }

    /// **唯一**建"带完整自适应 harness 的经典会话"的入口(classic 主会话 + nested spine/inner 共用)。
    func makeSession(id: String, system: String?, initialMessages: [LingShuAgentMessage] = [],
                     tools: [LingShuAgentTool], model: any LingShuAgentModel,
                     maxTurns: Int, maxHistoryMessages: Int, blockingToolNames: Set<String>) -> LingShuAgentSession {
        let catalog = applyCatalog(tools)
        return LingShuAgentSession(
            id: id, system: system, initialMessages: initialMessages, tools: catalog.tools,
            model: model, maxTurns: maxTurns, maxHistoryMessages: maxHistoryMessages, blockingToolNames: blockingToolNames,
            toolDispatcher: dispatcher(),
            historyCompactor: compactor(maxHistoryMessages: maxHistoryMessages),
            factSink: factSink,
            exposedToolNames: catalog.exposed
        )
    }
}
