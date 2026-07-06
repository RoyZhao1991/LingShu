import XCTest
@testable import LingShuMac

/// 脚本化 mock 模型:按预设序列逐轮返回(工具调用或文本),用于脱网测试编排循环。
private final class ScriptedAgentModel: LingShuAgentModel, @unchecked Sendable {
    private let script: [LingShuAgentModelResponse]
    private var index = 0
    private(set) var sawToolResults: [String] = []

    init(_ script: [LingShuAgentModelResponse]) { self.script = script }

    // 由 LingShuAgentSession(actor)串行调用,无并发,无需加锁。
    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
        // 记录上一轮回灌的工具结果,证明结果确实回到了模型上下文。
        if let last = messages.last, last.role == .tool {
            sawToolResults.append(last.content)
        }
        defer { index += 1 }
        return index < script.count ? script[index] : .text("(脚本耗尽)")
    }
}

final class AgentLoopTests: XCTestCase {

    func testModelCallsToolThenFinishes() async {
        let model = ScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "search", argumentsJSON: "{\"q\":\"灵枢\"}")]),
            .text("已根据检索结果作答")
        ])
        let searchTool = LingShuAgentTool(name: "search", description: "检索") { _ in "检索结果:命中3条" }
        let session = LingShuAgentSession(id: "s1", tools: [searchTool], model: model)

        let result = await session.send("查一下灵枢")
        XCTAssertEqual(result, .completed(text: "已根据检索结果作答"))
        let invocations = await session.toolInvocations
        XCTAssertEqual(invocations, ["search"])
        // 工具结果确实回灌进了模型上下文。
        XCTAssertEqual(model.sawToolResults, ["检索结果:命中3条"])
    }

    func testMultipleToolsInOneTurnExecuteInOrder() async {
        let model = ScriptedAgentModel([
            .toolCalls([
                .init(id: "c1", name: "a", argumentsJSON: "{}"),
                .init(id: "c2", name: "b", argumentsJSON: "{}")
            ]),
            .text("两个工具都跑完了")
        ])
        let toolA = LingShuAgentTool(name: "a", description: "A") { _ in "A-ok" }
        let toolB = LingShuAgentTool(name: "b", description: "B") { _ in "B-ok" }
        let session = LingShuAgentSession(id: "s2", tools: [toolA, toolB], model: model)

        let result = await session.send("做 A 和 B")
        XCTAssertEqual(result, .completed(text: "两个工具都跑完了"))
        let invocations = await session.toolInvocations
        XCTAssertEqual(invocations, ["a", "b"])
    }

    func testUnknownToolFeedsBackError() async {
        let model = ScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "ghost", argumentsJSON: "{}")]),
            .text("已处理未知工具")
        ])
        let session = LingShuAgentSession(id: "s3", tools: [], model: model)
        let result = await session.send("调一个不存在的工具")
        XCTAssertEqual(result, .completed(text: "已处理未知工具"))
        XCTAssertTrue(model.sawToolResults.first?.contains("未知工具") ?? false)
    }

    func testPlainAnswerNoTools() async {
        let model = ScriptedAgentModel([.text("你好，我是灵枢")])
        let session = LingShuAgentSession(id: "s4", tools: [], model: model)
        let result = await session.send("你好")
        XCTAssertEqual(result, .completed(text: "你好，我是灵枢"))
        let invocations = await session.toolInvocations
        XCTAssertTrue(invocations.isEmpty)
    }

    func testBoundedHistoryTrimsOldTurnsButKeepsSystemAndLatest() async {
        // 常驻会话设了历史窗口:多轮后旧上下文在回合边界被裁,系统身份恒保留、最近一轮恒保留——
        // 杜绝旧任务无限堆积污染新请求(根因 1a)。
        let model = ScriptedAgentModel([])   // 每轮返回"(脚本耗尽)"文本 → 单轮收尾
        let session = LingShuAgentSession(id: "trim", system: "系统身份", tools: [], model: model, maxHistoryMessages: 4)
        for i in 0..<10 { _ = await session.send("第\(i)轮") }

        let msgs = await session.messages
        XCTAssertEqual(msgs.first?.role, .system, "系统消息恒在最前")
        let body = msgs.filter { $0.role != .system }
        XCTAssertLessThanOrEqual(body.count, 6, "非系统历史被裁到窗口附近(窗口4 + 当轮 user+assistant)")
        XCTAssertNotEqual(body.first?.role, .tool, "裁剪后不留孤儿 tool 结果")
        XCTAssertTrue(msgs.contains { $0.content == "第9轮" }, "最近一轮永远保留")
        XCTAssertFalse(msgs.contains { $0.content == "第0轮" }, "最早的旧轮已被裁掉")
    }

    func testMidFlightCorrectionSteersTheLoop() async {
        // 模拟用户看到 agent 跑偏后中途纠正:循环在回合边界采纳纠正,模型下一步据此改方向。
        final class InjectingModel: LingShuAgentModel, @unchecked Sendable {
            weak var session: LingShuAgentSession?
            var step = 0
            private(set) var sawCorrection = false
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .user && $0.content.contains("改用 markdown") }) {
                    sawCorrection = true
                    return .text("已按你的纠正改用 markdown 重做完成")
                }
                step += 1
                if step == 1 {
                    // 第 1 步:模拟用户中途下达纠正(干预),同时模型还在按错方向继续。
                    await session?.injectCorrection("方向不对,改用 markdown")
                    return .toolCalls([.init(id: "c1", name: "noop", argumentsJSON: "{}")])
                }
                return .text("（按错误方向收尾）")
            }
        }
        let model = InjectingModel()
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "ok" }
        let session = LingShuAgentSession(id: "fix", tools: [noop], model: model)
        model.session = session

        let result = await session.send("做个东西")
        XCTAssertEqual(result, .completed(text: "已按你的纠正改用 markdown 重做完成"))
        XCTAssertTrue(model.sawCorrection, "纠正应在回合边界注入,模型下一步能看到")
        let messages = await session.messages
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content.contains("最高优先级") && $0.content.contains("改用 markdown") },
                      "纠正应作为最高优先级 user 指令注入上下文")
    }

    func testSubtaskBriefingSyncsToMainThreadOnNextTurn() async {
        // 子任务完成 → 简报回灌主线程:下一回合作为 system 提示注入(信息同步,非完整上下文)。
        final class CaptureModel: LingShuAgentModel, @unchecked Sendable {
            private(set) var sawBriefing = false
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .system && $0.content.contains("子任务进展简报") && $0.content.contains("抓取100条") }) {
                    sawBriefing = true
                }
                return .text("ok")
            }
        }
        let model = CaptureModel()
        let session = LingShuAgentSession(id: "main", tools: [], model: model)
        await session.injectBriefing("子任务「爬虫」已完成:抓取100条")
        _ = await session.send("接着干")
        XCTAssertTrue(model.sawBriefing, "子任务简报应在下一回合以 system 提示同步进主线程上下文")
    }

    func testCompactionRunsAfterCurrentInputAndEmitsTrace() async {
        // 第7站:当前输入应先入上下文再压缩。否则历史刚好越界时,本轮目标可能带着过量上下文进模型,
        // 且压缩不可追溯。这里验证:旧段被压成提要、当前用户目标仍在、trace 记录压缩账单。
        final class CompressionAwareModel: LingShuAgentModel, @unchecked Sendable {
            private(set) var capturedRuntimeMessages: [LingShuAgentMessage] = []
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .system && $0.content.contains("对话压缩器") }) {
                    return .text("@@SUMMARY@@\n早段已经折叠\n@@FACTS@@\n旧事实A")
                }
                capturedRuntimeMessages = messages
                return .text("已收到当前目标")
            }
        }
        final class TraceBox: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [LingShuAgentLoopTraceEvent] = []
            func append(_ event: LingShuAgentLoopTraceEvent) {
                lock.lock()
                values.append(event)
                lock.unlock()
            }
            func all() -> [LingShuAgentLoopTraceEvent] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }

        let model = CompressionAwareModel()
        let oldText = String(repeating: "旧上下文需要折叠", count: 80)
        var initial: [LingShuAgentMessage] = []
        for i in 0..<20 {
            initial.append(.init(role: i % 2 == 0 ? .user : .assistant, content: "\(oldText)#\(i)"))
        }
        let traces = TraceBox()
        let session = LingShuAgentSession(
            id: "compact-trace",
            system: "系统身份",
            initialMessages: initial,
            tools: [],
            model: model,
            maxHistoryMessages: 80,
            historyCompactor: LingShuLayeredCompactor(tokenBudget: 1_000, keepRecentTokens: 500),
            loopTraceSink: { event in traces.append(event) }
        )

        let current = "这是本轮当前目标,压缩后必须保留"
        let result = await session.send(current)

        XCTAssertEqual(result, .completed(text: "已收到当前目标"))
        XCTAssertTrue(model.capturedRuntimeMessages.contains { $0.role == .user && $0.content == current },
                      "当前输入应参与压缩后的模型上下文,不能被旧历史挤掉")
        XCTAssertTrue(model.capturedRuntimeMessages.contains { $0.content.contains("前情提要") },
                      "超预算旧历史应折叠为前情提要")
        let compactionTrace = traces.all().first { $0.title == "第7站压缩" }
        XCTAssertNotNil(compactionTrace, "压缩发生时必须留下可追溯 trace")
        XCTAssertTrue(compactionTrace?.detail.contains("tokens=") ?? false)
        XCTAssertTrue(compactionTrace?.detail.contains("messages=") ?? false)
        XCTAssertTrue(compactionTrace?.detail.contains("facts=1") ?? false)
    }

    func testCompactionKeepsCacheFriendlyStablePrefixAcrossShortFollowups() async {
        // 第7站成本守卫:一次压缩后应显著降低上下文体积,并给后续短 turn 留出余量。
        // 如果每轮都重新摘要,模型侧 prefix cache 会被打碎,账单和延迟都会上升。
        final class CacheAwareModel: LingShuAgentModel, @unchecked Sendable {
            private(set) var compressionCalls = 0
            private(set) var runtimeTokenSnapshots: [Int] = []
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .system && $0.content.contains("对话压缩器") }) {
                    compressionCalls += 1
                    return .text("@@SUMMARY@@\n稳定摘要:早段目标、约束和产出物路径已经折叠。\n@@FACTS@@\n旧事实A")
                }
                runtimeTokenSnapshots.append(LingShuTokenEstimator.estimate(messages))
                return .text("已处理")
            }
        }

        let model = CacheAwareModel()
        let oldText = String(repeating: "这是一段需要被压缩的早期上下文,包含目标约束和中间过程。", count: 70)
        var initial: [LingShuAgentMessage] = []
        for i in 0..<18 {
            initial.append(.init(role: i % 2 == 0 ? .user : .assistant, content: "\(oldText)#\(i)"))
        }
        let rawInitialTokens = LingShuTokenEstimator.estimate(initial)
        let compactor = LingShuLayeredCompactor(tokenBudget: 1_200, keepRecentTokens: 400)
        let session = LingShuAgentSession(
            id: "cache-friendly-compaction",
            system: "系统身份",
            initialMessages: initial,
            tools: [],
            model: model,
            maxHistoryMessages: 80,
            historyCompactor: compactor
        )

        _ = await session.send("当前目标必须保留")
        let afterFirstMessages = await session.messages
        let afterFirstTokens = LingShuTokenEstimator.estimate(afterFirstMessages.filter { $0.role != .system })
        XCTAssertEqual(model.compressionCalls, 1, "首次越界只应压缩一次")
        XCTAssertLessThan(afterFirstTokens, rawInitialTokens / 2, "压缩后上下文 token 应显著下降,否则成本没有被实质降低")
        XCTAssertLessThanOrEqual(afterFirstTokens, 1_200, "压缩后应落回预算内,给后续 turn 留出 cache-friendly 余量")
        XCTAssertTrue(afterFirstMessages.contains { $0.content.contains("稳定摘要") })
        XCTAssertTrue(afterFirstMessages.contains { $0.content == "当前目标必须保留" })

        _ = await session.send("短追问一")
        _ = await session.send("短追问二")
        _ = await session.send("短追问三")

        XCTAssertEqual(model.compressionCalls, 1, "压缩后的短追问不应重新蒸馏摘要,否则会破坏热缓存前缀")
        let finalMessages = await session.messages
        XCTAssertEqual(finalMessages.filter { $0.content.contains("稳定摘要") }.count, 1, "稳定摘要应作为单一前缀延续")
        XCTAssertTrue(model.runtimeTokenSnapshots.dropFirst().allSatisfy { $0 < 1_200 },
                      "后续短 turn 的模型上下文应继续处在预算内")
    }

    func testTaskDeliveryReplyClassification() {
        // 任务交付报告(声称产出文件/含代码/含路径)→ 念摘要;干净对话/汇报正文 → 念全文。
        XCTAssertTrue(LingShuState.replyLooksLikeTaskDelivery("已生成 /Users/x/a.pptx,共 10 页。"))
        XCTAssertTrue(LingShuState.replyLooksLikeTaskDelivery("脚本如下:\n```python\nprint(1)\n```"))
        XCTAssertFalse(LingShuState.replyLooksLikeTaskDelivery("我是灵枢,由 Roy Zhao 打造,很高兴见到你。"))
        XCTAssertFalse(LingShuState.replyLooksLikeTaskDelivery("今天的会议要点是:先对齐目标,再分工推进,最后定下周复盘时间。"))
    }

    func testMaxTurnsGuardStopsRunawayLoop() async {
        // 模型每轮都要调工具、永不收尾 → 应在 maxTurns 处停。
        let loopingScript = Array(repeating: LingShuAgentModelResponse.toolCalls([.init(id: "c", name: "noop", argumentsJSON: "{}")]), count: 50)
        let model = ScriptedAgentModel(loopingScript)
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "ok" }
        let session = LingShuAgentSession(id: "s5", tools: [noop], model: model, maxTurns: 3)
        let result = await session.send("无限循环")
        if case .maxTurnsReached = result {
            let used = await session.turnsUsed
            XCTAssertEqual(used, 3)
        } else {
            XCTFail("应触发 maxTurns 守卫")
        }
    }

    func testStuckRepeatHandsBackBeforeCeiling() async {
        // 目标驱动:模型连续发起完全相同的工具调用=原地打转,应在停滞阈值处诚实交还,
        // 而不是空转到(高位)安全天花板。证明停止位是"停滞",不是固定轮数预算。
        let spinScript = Array(repeating: LingShuAgentModelResponse.toolCalls([.init(id: "c", name: "noop", argumentsJSON: "{\"q\":\"same\"}")]), count: 50)
        let model = ScriptedAgentModel(spinScript)
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "still stuck" }
        let session = LingShuAgentSession(id: "s7", tools: [noop], model: model, maxTurns: 40)
        let result = await session.send("原地打转")
        guard case .maxTurnsReached = result else { return XCTFail("停滞应触发交还") }
        let used = await session.turnsUsed
        XCTAssertEqual(used, LingShuAgentSession.stuckRepeatThreshold, "应在停滞阈值处停,而非跑满天花板")
        XCTAssertLessThan(used, 40, "停止位是停滞检测,不是 maxTurns 天花板")
    }

    func testBigArgEmptySteersToChunkingEarly() async {
        // 真实战(30min 报告任务)挖出:write_file 的 content 因单次体积过大被通道截断,**空着到达**,模型自认已带齐、
        // 反复整块重传,最终自己绕了 20+ 轮才悟出"分块写"。本测证明:harness 在第 2 次空 content 就识别并 steer 到分块,
        // 模型据此一步收尾——把弯路从 20+ 轮压到 2 轮。
        final class StripsContentModel: LingShuAgentModel, @unchecked Sendable {
            private(set) var writeAttempts = 0
            private(set) var sawChunkSteer = false
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .user && $0.content.contains("分块写小段") }) {
                    sawChunkSteer = true
                    return .text("已改用 heredoc 分块写,文件已落盘完成")
                }
                writeAttempts += 1   // 每轮都"整块写"——但 content 被通道吞掉,只剩 path
                return .toolCalls([.init(id: "w\(writeAttempts)", name: "write_file",
                                        argumentsJSON: "{\"path\":\"/Users/x/report.py\"}")])
            }
        }
        let model = StripsContentModel()
        // write_file 工具按真实 schema 声明 content 必需,停滞检测才能据此判"漏必需参数"。
        let writeFile = LingShuAgentTool(
            name: "write_file", description: "写文件",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}"
        ) { _ in "已写入(但 content 为空)" }
        let session = LingShuAgentSession(id: "bigarg", tools: [writeFile], model: model, maxTurns: 40)

        let result = await session.send("生成一份很大的报告脚本并运行")
        XCTAssertEqual(result, .completed(text: "已改用 heredoc 分块写,文件已落盘完成"))
        XCTAssertTrue(model.sawChunkSteer, "应在空 content 反复出现时 steer 到分块写")
        XCTAssertEqual(model.writeAttempts, LingShuAgentSession.bigArgEmptyChunkSteerThreshold,
                       "第 2 次空 content 就该 steer,不应让模型整块重传超过阈值")
        let messages = await session.messages
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content.contains("被通道截断丢了") && $0.content.contains("cat >>") },
                      "纠偏应明确告知是体积截断、并给出 heredoc 分块的确定性做法")
    }

    func testInvalidRunCommandArgumentIsRejectedAndSteeredBeforeHandler() async {
        // 真实战收口 C03:模型把「约束**」这类说明/Markdown 片段塞进 run_command.command。
        // 通用修复应在工具契约层拦截,不让它进入真实 shell,再把结构化错误回灌给模型自行改路。
        final class BadCommandModel: LingShuAgentModel, @unchecked Sendable {
            private(set) var sawContractSteer = false
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .user && $0.content.contains("工具调用参数没有满足工具契约") }) ||
                    messages.contains(where: { $0.role == .tool && $0.content.contains("run_command.command 看起来不是可执行 shell 命令") }) {
                    sawContractSteer = true
                    return .text("已改用正确工具续接完成")
                }
                return .toolCalls([.init(id: "bad-cmd", name: "run_command", argumentsJSON: #"{"command":"约束**"}"#)])
            }
        }

        let model = BadCommandModel()
        let invoked = BoolBox()
        let run = LingShuAgentTool(
            name: "run_command",
            description: "执行 shell 命令",
            parametersJSON: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
        ) { _ in
            await invoked.set(true)
            return "SHOULD_NOT_RUN"
        }
        let session = LingShuAgentSession(id: "bad-run-command", tools: [run], model: model, maxTurns: 8)

        let result = await session.send("续接任务")

        XCTAssertEqual(result, .completed(text: "已改用正确工具续接完成"))
        XCTAssertTrue(model.sawContractSteer)
        let wasInvoked = await invoked.get()
        XCTAssertFalse(wasInvoked, "无效 command 必须在 dispatcher 前被拦截,不能真的进入 shell handler")
        let messages = await session.messages
        XCTAssertTrue(messages.contains { $0.role == .tool && $0.content.contains("参数无效") })
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content.contains("不要把说明文字") })
    }

    func testReadOnlyStallHandsBackWhenNeverMutating() async {
        // 弱模型只反复读/查看、从不动手改:停滞检测抓不到(每次参数不同),但「只读空转门」应在阈值处诚实交还,
        // 而非跑满天花板。证明对各种模型的犹豫空转有兜底。
        var script: [LingShuAgentModelResponse] = []
        for i in 0..<40 { script.append(.toolCalls([.init(id: "c\(i)", name: "read_file", argumentsJSON: "{\"path\":\"/f\",\"offset\":\(i)}")])) }
        let model = ScriptedAgentModel(script)
        let readTool = LingShuAgentTool(name: "read_file", description: "读") { _ in "文件内容若干…" }
        let session = LingShuAgentSession(id: "s-ro", tools: [readTool], model: model, maxTurns: 40)
        let result = await session.send("迭代这个文件")
        guard case .maxTurnsReached = result else { return XCTFail("只读空转应触发交还") }
        let used = await session.turnsUsed
        XCTAssertLessThanOrEqual(used, LingShuAgentSession.readOnlyStallForceAt, "应在只读空转阈值处停,而非跑满天花板")
        XCTAssertLessThan(used, 40)
    }

    func testToolReceivesArgumentsJSON() async {
        let model = ScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "echo", argumentsJSON: "{\"text\":\"在\"}")]),
            .text("done")
        ])
        let captured = ArgsBox()
        let echo = LingShuAgentTool(name: "echo", description: "回显") { args in
            await captured.set(args)
            return "ok"
        }
        let session = LingShuAgentSession(id: "s6", tools: [echo], model: model)
        _ = await session.send("回显")
        let got = await captured.value
        XCTAssertEqual(got, "{\"text\":\"在\"}")
    }
}

private actor ArgsBox {
    private(set) var value: String = ""
    func set(_ v: String) { value = v }
}

private actor BoolBox {
    private(set) var value = false
    func set(_ v: Bool) { value = v }
    func get() -> Bool { value }
}
