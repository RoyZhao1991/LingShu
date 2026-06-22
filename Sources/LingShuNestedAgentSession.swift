import Foundation

/// **嵌套分阶段 agent 循环**(`.nested`):实现 `LingShuAgentSessioning`(drop-in,工厂/holder/验收/编排器无改动复用)。
///
/// 设计(用户定调):大 LOOP 含多个子 LOOP(阶段)。一次请求 → 规划成有序【阶段】,每阶段标 任务/互动:
/// - **任务阶段**:起一段经典 `LingShuAgentSession` 子运行(带该阶段工具 + 前序产物上下文)跑到收尾,
///   再复用 `verifyAgentDeliverable` 按交付物验收;不过则**本阶段内返工**,过了进下一阶段。
/// - **互动阶段**:不验交付物;是"活的"(演示/答疑),完成信号=主人确认没后续。复用现有演示/收尾机制。
/// - **大 LOOP 终验** = 各任务阶段交付物已验 + 各互动阶段完成信号齐。
///
/// **简单请求(非多阶段)走持久 spine 会话直通** = 与经典循环行为一致 → `.nested` 对简单流程零影响,
/// 只在多阶段请求时启用流水线。全程可被唤醒词/打断中止(`isInterrupted`/`Task.isCancelled`),**继续=从断点阶段续**。
///
/// **验收门旁路 bug 在本新引擎修复**:每次开始一段新驱动(送新请求 / 断点续接)入口先 `consumeInterrupt` 复位打断标志,
/// 让打断只对它针对的那一段工作生效、不泄漏到后续阶段的验收(经典引擎的粘滞标志问题不在此复现)。
actor LingShuNestedAgentSession: LingShuAgentSessioning {

    // MARK: - 构造参数(经工厂注入,不依赖 LingShuState 类型)
    private let id: String
    private let system: String?
    private let initialMessages: [LingShuAgentMessage]
    private let tools: [LingShuAgentTool]
    private let model: any LingShuAgentModel
    private let maxTurns: Int
    private let maxHistoryMessages: Int
    private let blockingToolNames: Set<String>

    /// 任务阶段验收:复用整套 `verifyAndContinue`(独立 verifier + 撞顶恢复 + 多轮验收 + 停滞检测 + 非代码返工预算)。
    /// 把该阶段内层会话 + 其收尾结果交进去,驱动到验收通过(或停滞交还),返回最终结果。互动阶段不调它。
    private let acceptStage: @MainActor @Sendable (_ stageSession: any LingShuAgentSessioning, _ stageResult: LingShuAgentRunResult, _ stageTitle: String) async -> LingShuAgentRunResult
    /// 落一条 trace(分阶段流水线的可观测:规划/阶段开始/终验/断点)。
    private let note: @MainActor @Sendable (_ title: String, _ detail: String) -> Void
    /// 切 LOOP 阶段显示(规划中;结果验证由 verifyStage 内部置;idle 复位)。
    private let setPhase: @MainActor @Sendable (LingShuLoopPhase) -> Void
    /// 是否收到打断(唤醒词 barge / 主人插话置 batchInterruptRequested)。
    private let isInterrupted: @MainActor @Sendable () -> Bool
    /// 消费/复位打断标志(开始新一段驱动时调,杜绝粘滞标志泄漏到后续阶段验收)。
    private let consumeInterrupt: @MainActor @Sendable () -> Void
    /// 长期记忆自动召回块(只在简单请求直通时注入 spine,不进规划文本):保留与经典一致的"每轮自动召回"能力。
    private let recallMemory: @MainActor @Sendable (String) async -> String
    /// 统一自适应 harness 配置(骨架 #2):spine/各阶段 inner 据它建会话,吃齐与 .classic 同一套(并行调度/token压缩/
    /// factSink/按脑力延迟加载)。nil=回退裸 `LingShuAgentSession`(向后兼容、测试默认)。
    private let harness: LingShuHarnessConfig?

    // MARK: - 内部状态机
    private enum Phase: Equatable {
        case conversational            // 无进行中的流水线 → 走 spine(简单请求直通 + 跨回合连续性)
        case awaitingInteraction(Int)  // 第 i 阶段是互动、已开场,等主人下一句(说"结束/没了"进下一阶段)
        case awaitingResume(Int)       // 第 i 阶段被打断,存断点,等"继续"从该阶段续
    }
    private var phase: Phase = .conversational
    private var stages: [LingShuNestedStage] = []
    private var priorSummaries: [String] = []
    private var originalRequest = ""
    private var spine: LingShuAgentSession?              // 持久对话会话(简单请求 + 连续性)
    private var interactionInner: LingShuAgentSession?   // 当前互动阶段的内层会话(续答疑/翻页时复用)
    private var activeInner: LingShuAgentSession?        // 当前在跑的内层会话(continueLoop/断网重连用)
    private var pipelineActive = false                  // 是否处在分阶段流水线中(决定 continueLoop 走法)
    /// spine 观测面增量基线:`turnsUsed`/`toolInvocations` 必须**单调累加**(可观测计数器倒退=robustness bug,
    /// 嵌套混沌测试实锤)。流水线阶段是"加"(`+= inner.turnsUsed`),故 spine 同步也必须"加增量"而非覆盖,
    /// 否则跑过流水线(turnsUsed 累高)后再走 spine 直通会被 spine 的小计数覆盖、倒退。
    private var spineLastTurns = 0
    private var spineLastToolCount = 0

    // MARK: - 协议观测面
    private(set) var turnsUsed = 0
    private(set) var toolInvocations: [String] = []
    private(set) var messages: [LingShuAgentMessage] = []
    private var textDeltaSink: (@Sendable (String) async -> Void)?
    private var spineBlocked = false

    init(
        id: String,
        system: String?,
        initialMessages: [LingShuAgentMessage],
        tools: [LingShuAgentTool],
        model: any LingShuAgentModel,
        maxTurns: Int,
        maxHistoryMessages: Int,
        blockingToolNames: Set<String>,
        acceptStage: @escaping @MainActor @Sendable (any LingShuAgentSessioning, LingShuAgentRunResult, String) async -> LingShuAgentRunResult,
        note: @escaping @MainActor @Sendable (String, String) -> Void,
        setPhase: @escaping @MainActor @Sendable (LingShuLoopPhase) -> Void,
        isInterrupted: @escaping @MainActor @Sendable () -> Bool,
        consumeInterrupt: @escaping @MainActor @Sendable () -> Void,
        recallMemory: @escaping @MainActor @Sendable (String) async -> String = { _ in "" },
        harness: LingShuHarnessConfig? = nil
    ) {
        self.id = id
        self.system = system
        self.initialMessages = initialMessages
        self.tools = tools
        self.model = model
        self.maxTurns = max(1, maxTurns)
        self.maxHistoryMessages = max(0, maxHistoryMessages)
        self.blockingToolNames = blockingToolNames
        self.acceptStage = acceptStage
        self.note = note
        self.setPhase = setPhase
        self.isInterrupted = isInterrupted
        self.consumeInterrupt = consumeInterrupt
        self.recallMemory = recallMemory
        self.harness = harness
        self.messages = initialMessages
    }

    var isBlocked: Bool { spineBlocked }

    func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {
        textDeltaSink = sink
    }

    // MARK: - 协议入口:send / resume / continueLoop / inject

    /// 投入用户输入。主前台会话走这条(每次都 send);据相位决定:新请求 / 推进互动 / 断点续接。
    func send(_ userText: String) async -> LingShuAgentRunResult {
        await drive(userText, isResume: false)
    }

    /// 续接。在岗/自主会话走这条。spine 卡在 ask_user 时回填答案;否则与 send 同路(据相位)。
    func resume(_ answer: String) async -> LingShuAgentRunResult {
        if case .conversational = phase, spineBlocked, let s = spine {
            let r = await s.resume(answer)
            await syncFromSpine(s)
            return r
        }
        return await drive(answer, isResume: true)
    }

    /// 重连续跑(断网恢复):接着当前在跑的内层会话续;流水线中则从断点阶段重驱。
    func continueLoop() async -> LingShuAgentRunResult {
        if pipelineActive, case .awaitingResume(let i) = phase {
            return await drivePipeline(fromStage: i)
        }
        if let inner = activeInner {
            let r = await inner.continueLoop()
            if inner === spine { await syncFromSpine(inner) }
            return r
        }
        return .completed(text: "")
    }

    /// 纠正注入到当前活跃内层会话(回合边界采纳)。sync 协议方法 → 转发用 detached(best-effort,顺序对纠正不敏感)。
    func injectCorrection(_ text: String) -> Bool {
        guard let inner = activeInner ?? interactionInner ?? spine else { return false }
        Task { await inner.injectCorrection(text) }
        return pipelineActive || phase != .conversational
    }

    /// 子任务简报注入持久 spine(跨回合信息同步)。
    func injectBriefing(_ text: String) {
        let s = ensureSpine()
        Task { await s.injectBriefing(text) }
    }

    // MARK: - 驱动核心

    /// 据相位分流:互动续 / 断点续 / 新请求。入口先消费打断标志(杜绝粘滞泄漏)。
    private func drive(_ text: String, isResume: Bool) async -> LingShuAgentRunResult {
        switch phase {
        case .awaitingInteraction(let i):
            return await continueInteraction(stageIndex: i, userText: text)
        case .awaitingResume(let i):
            await consumeInterrupt()   // 断点续接:消费打断标志,新这段不被旧标志立刻中止
            await note("断点续接", "从第 \(i + 1) 阶段续(不重头)。")
            return await drivePipeline(fromStage: i)
        case .conversational:
            await consumeInterrupt()
            return await handleFresh(text, isResume: isResume)
        }
    }

    /// 新请求:简单 → spine 直通(等价经典);多阶段 → 规划 + 流水线。
    private func handleFresh(_ text: String, isResume: Bool) async -> LingShuAgentRunResult {
        originalRequest = text
        pipelineActive = false
        stages = []; priorSummaries = []
        phase = .conversational
        guard LingShuNestedStagePlanner.shouldPlanStages(text) else {
            // 直通:走 spine = 经典连续循环,行为与 .classic 一致(对简单请求零影响)。
            // 注入长期记忆自动召回(只在直通注入,不污染规划)→ 保留经典的"每轮自动召回"能力。
            let mem = await recallMemory(text)
            let spineInput = mem.isEmpty ? text : "\(mem)\n\n\(text)"
            let s = ensureSpine()
            activeInner = s
            if let sink = textDeltaSink { await s.setTextDeltaSink(sink) }
            let r = isResume ? await s.resume(spineInput) : await s.send(spineInput)
            await syncFromSpine(s)
            return r
        }
        // 多阶段:一次模型调用产出阶段列表(解析失败兜底单任务阶段)。
        await setPhase(.planning)
        await note("规划", "把请求拆成有序阶段…")
        let planned = await planStages(text)
        stages = planned
        pipelineActive = true
        let desc = planned.enumerated().map { "\($0.offset + 1).[\($0.element.kind == .task ? "任务" : "互动")]\($0.element.title)" }.joined(separator: " ")
        await note("规划完成", "共 \(planned.count) 个阶段:\(desc)")
        return await drivePipeline(fromStage: 0)
    }

    /// 从指定阶段起逐阶段推进。任务阶段验收+返工,互动阶段开场后让出等主人。
    private func drivePipeline(fromStage start: Int) async -> LingShuAgentRunResult {
        var i = start
        var lastText = ""
        while i < stages.count {
            let interruptedNow = await isInterrupted()
            if Task.isCancelled || interruptedNow {
                phase = .awaitingResume(i)
                await note("打断", "在第 \(i + 1) 阶段被打断,已存断点;说『继续』从这里续。")
                await setPhase(.idle)
                return .completed(text: lastText.isEmpty ? "已停在第 \(i + 1) 阶段,随时说『继续』我接着做。" : lastText)
            }
            let stage = stages[i]
            await note("阶段开始", "第 \(i + 1)/\(stages.count) [\(stage.kind == .task ? "任务" : "互动")] \(stage.title)")
            let input = LingShuNestedStagePlanner.stageInput(stage: stage, index: i, total: stages.count, priorSummaries: priorSummaries, originalRequest: originalRequest)
            let inner = makeInner(idSuffix: "s\(i)")
            activeInner = inner
            if let sink = textDeltaSink { await inner.setTextDeltaSink(sink) }
            var result = await inner.send(input)
            turnsUsed += await inner.turnsUsed
            toolInvocations += await inner.toolInvocations
            if case .interrupted = result {   // 断网:挂起,保留断点,交还 .interrupted 由上层暂停/重连续
                phase = .awaitingResume(i)
                return result
            }
            if stage.kind == .task {
                // 任务阶段:复用整套 verifyAndContinue(撞顶恢复 + 多轮验收 + 停滞检测 + 非代码返工预算 + [验收]通过 trace),
                // 把内层会话驱动到验收通过(或停滞交还)。全程可被打断(verifyAndContinue 内查 Task.isCancelled/batchInterruptRequested)。
                result = await acceptStage(inner, result, stage.title)
                if case .interrupted = result { phase = .awaitingResume(i); return result }
                let interruptedAfter = await isInterrupted()
                if Task.isCancelled || interruptedAfter {
                    phase = .awaitingResume(i)
                    await note("打断", "第 \(i + 1) 阶段验收后被打断,存断点。")
                    await setPhase(.idle)
                    return .completed(text: Self.text(result))
                }
                priorSummaries.append(Self.text(result))
                lastText = Self.text(result)
                i += 1
                continue
            } else {
                // 互动阶段:不验收。开场已做(open_preview/present/speak),让出等主人下一句。
                interactionInner = inner
                priorSummaries.append(Self.text(result))
                phase = .awaitingInteraction(i)
                await note("互动待续", "第 \(i + 1) 阶段已开场(不验收);主人说『结束/没了』我进下一阶段。")
                await setPhase(.idle)
                return result   // 交还本阶段回复,走标准收尾(朗读/呈现)
            }
        }
        return await finalizePipeline()
    }

    /// 互动阶段续:主人示意没后续 → 进下一阶段;否则把这句交给该互动阶段继续(答疑/翻页/接着讲)。
    private func continueInteraction(stageIndex i: Int, userText: String) async -> LingShuAgentRunResult {
        if LingShuNestedStagePlanner.isInteractionDone(userText) {
            await note("互动完成", "主人示意没后续,推进到下一阶段。")
            await consumeInterrupt()
            return await drivePipeline(fromStage: i + 1)
        }
        guard let inner = interactionInner else {
            phase = .conversational
            return await handleFresh(userText, isResume: true)
        }
        activeInner = inner
        if let sink = textDeltaSink { await inner.setTextDeltaSink(sink) }
        let r = await inner.resume(userText)
        turnsUsed += await inner.turnsUsed
        toolInvocations += await inner.toolInvocations
        phase = .awaitingInteraction(i)   // 仍在该互动阶段
        return r
    }

    /// 大 LOOP 终验:各任务阶段已验、各互动阶段已完成。聚合成一句交付,并喂回 spine 保持连续性。
    private func finalizePipeline() async -> LingShuAgentRunResult {
        await note("终验", "各任务阶段交付物已验收、各互动阶段已完成。")
        await setPhase(.idle)
        let summary = LingShuNestedStagePlanner.aggregateSummary(stages: stages, summaries: priorSummaries)
        let s = ensureSpine()
        Task { await s.injectBriefing("已完成一次分阶段请求「\(originalRequest.prefix(40))」:\(summary.prefix(400))") }
        phase = .conversational
        pipelineActive = false
        interactionInner = nil
        return .completed(text: summary)
    }

    // MARK: - 内层会话构造 + 观测同步

    private func ensureSpine() -> LingShuAgentSession {
        if let spine { return spine }
        // 骨架 #2:经统一 harness 建 spine,吃齐与 .classic 同一套自适应能力;无 harness 则回退裸会话(兼容)。
        let s = harness?.makeSession(id: "\(id)-spine", system: system, initialMessages: initialMessages, tools: tools,
                                     model: model, maxTurns: maxTurns, maxHistoryMessages: maxHistoryMessages, blockingToolNames: blockingToolNames)
            ?? LingShuAgentSession(id: "\(id)-spine", system: system, initialMessages: initialMessages, tools: tools,
                                   model: model, maxTurns: maxTurns, maxHistoryMessages: maxHistoryMessages, blockingToolNames: blockingToolNames)
        spine = s
        return s
    }

    /// 阶段内层会话:全工具 + 同系统提示,但**新鲜上下文**(只带本阶段输入,前序产物经文本上下文交接)。
    /// 同样经统一 harness 建(吃齐并行调度/按脑力延迟加载等),短命阶段 maxHistory=0 不压缩(原语义)。
    private func makeInner(idSuffix: String) -> LingShuAgentSession {
        harness?.makeSession(id: "\(id)-\(idSuffix)", system: system, tools: tools,
                             model: model, maxTurns: maxTurns, maxHistoryMessages: 0, blockingToolNames: blockingToolNames)
            ?? LingShuAgentSession(id: "\(id)-\(idSuffix)", system: system, tools: tools, model: model, maxTurns: maxTurns, blockingToolNames: blockingToolNames)
    }

    /// 规划:独立一次性会话(无工具),解析为阶段列表(纯函数,容错兜底)。
    private func planStages(_ request: String) async -> [LingShuNestedStage] {
        let planner = LingShuAgentSession(id: "\(id)-plan", system: LingShuNestedStagePlanner.plannerSystem, tools: [], model: model, maxTurns: 1)
        let r = await planner.send(LingShuNestedStagePlanner.planningPrompt(request))
        let text: String = { if case .completed(let t) = r { return t }; return "" }()
        return LingShuNestedStagePlanner.parsePlan(text, fallbackRequest: request)
    }

    private func syncFromSpine(_ s: LingShuAgentSession) async {
        messages = await s.messages
        spineBlocked = await s.isBlocked
        // turnsUsed / toolInvocations **只增量累加,绝不覆盖**(保证可观测计数器单调,见 spineLastTurns 注释)。
        let spineTurns = await s.turnsUsed
        if spineTurns > spineLastTurns { turnsUsed += spineTurns - spineLastTurns; spineLastTurns = spineTurns }
        let spineTools = await s.toolInvocations
        if spineTools.count > spineLastToolCount {
            toolInvocations += spineTools[spineLastToolCount...]
            spineLastToolCount = spineTools.count
        }
        activeInner = s
    }

    private static func text(_ r: LingShuAgentRunResult) -> String {
        switch r {
        case .completed(let t): return t
        case .blocked(let q): return q
        case .maxTurnsReached(let t): return t
        case .interrupted(let reason): return reason
        }
    }
}
