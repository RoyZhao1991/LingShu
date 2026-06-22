import XCTest
@testable import LingShuMac

/// Agent 循环属性/混沌测试(差距1·架网,2026-06-21):用**确定性随机**驱动循环跑成千上万种
/// {工具成功/失败/崩溃签名/空、终态文本、基建中断、阻塞、脚手架、原地打转、过度自测、中途纠正/简报、取消}
/// 组合,断言**循环不变量恒成立、永远到终态、turnsUsed 单调**。
///
/// - 通用:只测循环骨架(不变量),不测任何业务。
/// - 脱网可 CI:模型注入(`FuzzModel`)+ 工具输出是 args 的确定函数 → 整条运行由种子完全决定、失败可复现。
/// - 棘轮:任何 fuzz/真机发现的失败种子 → 固化进 `regressionSeeds`,只增不减。
final class AgentLoopFuzzTests: XCTestCase {

    // MARK: 确定性 PRNG(SplitMix64,纯 Swift,种子→完全可复现)

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 工具输出 = args 的确定函数(成功/错误/崩溃签名/空),保证整条运行可复现。
    static func deterministicOutcome(_ args: String) -> String {
        var h: UInt64 = 14695981039346656037   // FNV-1a 64 位 offset basis
        for b in args.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        switch h % 4 {
        case 0: return "ok: 完成"
        case 1: return "错误: 这步失败了,换个法子"
        case 2: return "Traceback (most recent call last):\n  IndexError: list index out of range"
        default: return ""
        }
    }

    /// 混沌模型:按种子随机产出循环要应对的各种响应,并以小概率在回合中途向会话注入纠正/简报。
    final class FuzzModel: LingShuAgentModel, @unchecked Sendable {
        private var rng: SplitMix64
        private var callSeq = 0
        weak var session: LingShuAgentSession?
        private let realToolNames = ["write_file", "edit_file", "read_file", "run_command", "web_search", "list_directory"]

        init(seed: UInt64) { rng = SplitMix64(seed) }
        private func roll(_ mod: UInt64) -> UInt64 { rng.next() % mod }
        private func nextID() -> String { callSeq += 1; return "fc\(callSeq)" }

        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            // 小概率中途注入纠正/简报(模拟用户干预 / 子任务回灌),考验回合边界采纳的良构性。
            switch roll(20) {
            case 0: await session?.injectCorrection("方向改一下,最高优先级")
            case 1: await session?.injectBriefing("子任务A已完成:产出若干")
            default: break
            }

            let r = roll(100)
            switch r {
            case 0..<12:
                return .text("【最终答复】已完成,产出在某路径。")
            case 12..<18:
                return .failed(reason: "网关不可达(混沌注入)")
            case 18..<24:
                // 阻塞工具,可能同回合还带一个非阻塞调用(考验"阻塞前清干净本回合")。
                var calls: [LingShuAgentToolCall] = []
                if roll(2) == 0 { calls.append(.init(id: nextID(), name: realToolNames[Int(roll(UInt64(realToolNames.count)))], argumentsJSON: "{\"x\":\(roll(5))}")) }
                calls.append(.init(id: nextID(), name: "ask_user", argumentsJSON: "{\"question\":\"需要确认吗?\"}"))
                return .toolCalls(calls)
            case 24..<32:
                // 可选脚手架工具反复调(考验 stuck-scaffold 不交还、注入纠偏后继续)。
                return .toolCalls([.init(id: nextID(), name: "update_plan", argumentsJSON: "{\"plan\":\"同一个计划\"}")])
            case 32..<46:
                // 原地打转:同名同参(id 仍唯一,签名靠 name#args)反复发起 → 触发停滞交还。
                return .toolCalls([.init(id: nextID(), name: "run_command", argumentsJSON: "{\"cmd\":\"same\"}")])
            default:
                // 1~3 个随机真工具(含 mutating,考验过度自测/只读空转门)。
                let n = Int(roll(3)) + 1
                var calls: [LingShuAgentToolCall] = []
                for _ in 0..<n {
                    let name = realToolNames[Int(roll(UInt64(realToolNames.count)))]
                    calls.append(.init(id: nextID(), name: name, argumentsJSON: "{\"v\":\(roll(7))}"))
                }
                return .toolCalls(calls)
            }
        }
    }

    /// 构造一组通用工具(handler 输出确定),覆盖 mutating / 只读 / 命令 / 脚手架 / 阻塞。
    private func fuzzTools() -> [LingShuAgentTool] {
        let names = ["write_file", "edit_file", "read_file", "run_command", "web_search", "list_directory", "update_plan", "ask_user"]
        return names.map { name in
            LingShuAgentTool(name: name, description: name) { args in AgentLoopFuzzTests.deterministicOutcome(name + args) }
        }
    }

    /// 断言一次运行后会话恒满足不变量;违反就打印种子(可复现)并 fail。
    private func assertHealthy(_ session: LingShuAgentSession, result: LingShuAgentRunResult, seed: UInt64,
                              prevTurns: Int, file: StaticString = #filePath, line: UInt = #line) async -> Int {
        let violations = await session.recordedInvariantViolations
        XCTAssertTrue(violations.isEmpty, "种子 \(seed):循环不变量被破坏 → \(violations.map(\.description))", file: file, line: line)
        let isBlocked = await session.isBlocked
        if case .blocked = result {
            XCTAssertTrue(isBlocked, "种子 \(seed):.blocked 结果但 isBlocked=false", file: file, line: line)
        } else {
            XCTAssertFalse(isBlocked, "种子 \(seed):非阻塞结果但 isBlocked=true(阻塞标志泄漏)", file: file, line: line)
        }
        let turns = await session.turnsUsed
        XCTAssertGreaterThanOrEqual(turns, prevTurns, "种子 \(seed):turnsUsed 应单调不减", file: file, line: line)
        return turns
    }

    /// 跑一条随机会话(随机 maxTurns/历史窗口 + 多次随机交互),全程断言不变量。
    /// `parallel`/`layered` 注入差距7-A/4 的可替换模块——让同一套混沌网也罩住生产新默认(并行调度 + token 分层压缩)。
    private func runOneFuzzSession(seed: UInt64, parallel: Bool = false, layered: Bool = false) async {
        var rng = SplitMix64(seed ^ 0xDEAD_BEEF)
        func roll(_ m: UInt64) -> UInt64 { rng.next() % m }
        let maxTurns = Int(roll(28)) + 2                    // 2…29
        let window = [0, 0, 2, 3, 5, 8][Int(roll(6))]       // 含 0(不裁)
        let model = FuzzModel(seed: seed)
        let dispatcher: any LingShuToolDispatching = parallel ? LingShuParallelToolDispatcher() : LingShuSerialToolDispatcher()
        // 小预算逼出频繁压缩,把"压缩点 × 并行工具 × 随机交互"的交叉路径都锤一遍。
        let compactor: (any LingShuHistoryCompacting)? = (layered && window > 0) ? LingShuLayeredCompactor(tokenBudget: 200, keepRecentTokens: 80) : nil
        let session = LingShuAgentSession(id: "fuzz-\(seed)", system: "你是测试体", tools: fuzzTools(),
                                          model: model, maxTurns: maxTurns, maxHistoryMessages: window,
                                          toolDispatcher: dispatcher, historyCompactor: compactor)
        model.session = session

        var prevTurns = 0
        let interactions = Int(roll(4)) + 1                 // 1…4 次交互
        var lastResult: LingShuAgentRunResult = .completed(text: "")
        for _ in 0..<interactions {
            let isBlocked = await session.isBlocked
            if isBlocked {
                lastResult = await session.resume("这是补给阻塞的答案 \(roll(99))")
            } else if case .interrupted = lastResult {
                lastResult = await session.continueLoop()    // 模拟断网重连续跑
            } else {
                lastResult = await session.send("随机任务 \(roll(9999))")
            }
            prevTurns = await assertHealthy(session, result: lastResult, seed: seed, prevTurns: prevTurns)
        }
    }

    // MARK: 主混沌循环

    func testChaosNoInvariantViolationsAcrossManySeeds() async {
        LingShuLoopInvariantTelemetry.reset()
        // CI 默认跑 300 条;LINGSHU_FUZZ_SEEDS 可调高做更深扫荡。
        let count = ProcessInfo.processInfo.environment["LINGSHU_FUZZ_SEEDS"].flatMap { Int($0) } ?? 300
        for i in 0..<count {
            await runOneFuzzSession(seed: UInt64(i) &* 2654435761 &+ 12345)
        }
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0,
                       "混沌扫荡中出现不变量违反(累计 \(LingShuLoopInvariantTelemetry.total)):\(LingShuLoopInvariantTelemetry.lastSamples)")
    }

    /// 差距4/7·过网:用**生产新默认模块**(并行工具调度 + token 分层压缩)跑同一套混沌扫荡,
    /// 断言并行执行/压缩点交叉下循环仍恒良构(无孤儿 tool_call、无标志泄漏、token 在预算内)。
    func testChaosWithNewHarnessModulesNoViolations() async {
        LingShuLoopInvariantTelemetry.reset()
        let count = ProcessInfo.processInfo.environment["LINGSHU_FUZZ_SEEDS"].flatMap { Int($0) } ?? 300
        for i in 0..<count {
            await runOneFuzzSession(seed: UInt64(i) &* 2654435761 &+ 999, parallel: true, layered: true)
        }
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0,
                       "并行+分层压缩下混沌扫荡出现不变量违反(累计 \(LingShuLoopInvariantTelemetry.total)):\(LingShuLoopInvariantTelemetry.lastSamples)")
    }

    // MARK: 棘轮 —— 历史失败种子永久回放(发现一个加一个,只增不减)

    /// 此处登记每一个被 fuzz/真机抓到过的失败种子。当前为空(架网首版尚无回归种子)。
    static let regressionSeeds: [UInt64] = []

    func testRegressionSeedsStayHealthy() async {
        LingShuLoopInvariantTelemetry.reset()
        for seed in Self.regressionSeeds {
            await runOneFuzzSession(seed: seed)
        }
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0, "回归种子复发:\(LingShuLoopInvariantTelemetry.lastSamples)")
    }

    // MARK: 定向属性测试(架网逼出来的两处良构修复)

    private final class Scripted: LingShuAgentModel, @unchecked Sendable {
        private let script: [LingShuAgentModelResponse]
        private var i = 0
        init(_ s: [LingShuAgentModelResponse]) { script = s }
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            defer { i += 1 }; return i < script.count ? script[i] : .text("(脚本耗尽)")
        }
    }

    func testStuckHandbackThenResumeStaysWellFormed() async {
        // 原地打转 5 次 → 停滞交还(这一步的 tool_calls 未执行)。随后 resume/续接绝不能因悬空未应答调用而不良构。
        var script = Array(repeating: LingShuAgentModelResponse.toolCalls([.init(id: "s", name: "run_command", argumentsJSON: "{\"cmd\":\"same\"}")]), count: 6)
        script.append(.text("换路后完成"))
        let model = Scripted(script)
        let tool = LingShuAgentTool(name: "run_command", description: "cmd") { _ in "stuck" }
        let session = LingShuAgentSession(id: "stuck-resume", tools: [tool], model: model, maxTurns: 40)

        let r1 = await session.send("反复跑同一条命令")
        guard case .maxTurnsReached = r1 else { return XCTFail("应停滞交还,实际 \(r1)") }
        var v = await session.recordedInvariantViolations
        XCTAssertTrue(v.isEmpty, "停滞交还后历史应良构(合成 tool 结果补齐):\(v)")

        let r2 = await session.resume("换条路继续")
        XCTAssertEqual(r2, .completed(text: "换路后完成"))
        v = await session.recordedInvariantViolations
        XCTAssertTrue(v.isEmpty, "停滞后续接不应产生不良构历史:\(v)")
        let reason = await session.lastExitReason
        XCTAssertEqual(reason, .normalCompletion)
    }

    func testBlockingWithExtraCallThenResumeStaysWellFormed() async {
        // 同回合 [write_file, ask_user]:阻塞前必须把 write_file 执行掉补结果,否则它成孤儿、resume 后网关 400。
        let model = Scripted([
            .toolCalls([.init(id: "w", name: "write_file", argumentsJSON: "{\"path\":\"/a\"}"),
                        .init(id: "ask", name: "ask_user", argumentsJSON: "{\"question\":\"确认?\"}")]),
            .text("拿到答案后完成"),
        ])
        let w = LingShuAgentTool(name: "write_file", description: "写") { _ in "已写入" }
        let ask = LingShuAgentTool(name: "ask_user", description: "问") { _ in "" }
        let session = LingShuAgentSession(id: "block-extra", tools: [w, ask], model: model, maxTurns: 40)

        let r1 = await session.send("写文件并问我一个问题")
        guard case .blocked = r1 else { return XCTFail("应阻塞等输入,实际 \(r1)") }
        var v = await session.recordedInvariantViolations
        XCTAssertTrue(v.isEmpty, "阻塞终态历史应良构(write_file 已补结果,仅 ask 悬挂):\(v)")
        let invocations = await session.toolInvocations
        XCTAssertTrue(invocations.contains("write_file"), "阻塞前应已执行同回合的非阻塞工具")

        let r2 = await session.resume("确认,继续")
        XCTAssertEqual(r2, .completed(text: "拿到答案后完成"))
        v = await session.recordedInvariantViolations
        XCTAssertTrue(v.isEmpty, "resume 后历史仍应良构:\(v)")
    }

    func testAskFormBlocksWithoutExecutingHandlerThenResume() async {
        actor Flag {
            private var value = false
            func set() { value = true }
            func get() -> Bool { value }
        }

        let args = """
        {"title":"确认汇报信息","fields":[{"key":"topic","question":"课题是什么","options":["灵枢"]}]}
        """
        let model = Scripted([
            .toolCalls([.init(id: "form", name: "ask_form", argumentsJSON: args)]),
            .text("拿到表单答案后继续"),
        ])
        let flag = Flag()
        let form = LingShuAgentTool(name: "ask_form", description: "表单") { _ in
            await flag.set()
            return "不应该执行到这里"
        }
        let session = LingShuAgentSession(id: "form-block", tools: [form], model: model, maxTurns: 10)

        let r1 = await session.send("需要确认多个事项")
        guard case .blocked(let prompt) = r1 else { return XCTFail("ask_form 应作为 human-in-the-loop 阻塞,实际 \(r1)") }
        let handlerExecuted = await flag.get()
        XCTAssertFalse(handlerExecuted, "ask_form handler 不应在阻塞时执行,否则会在 continuation 里卡住主循环")
        let envelope = LingShuHumanInputEnvelope.decode(from: prompt)
        XCTAssertEqual(envelope?.tool, "ask_form")
        XCTAssertEqual(envelope?.argumentsJSON, args)
        let blockedAfterForm = await session.isBlocked
        XCTAssertTrue(blockedAfterForm)

        let r2 = await session.resume("主人已确认以下事项:\n- 课题是什么 → 灵枢")
        XCTAssertEqual(r2, .completed(text: "拿到表单答案后继续"))
        let blockedAfterResume = await session.isBlocked
        XCTAssertFalse(blockedAfterResume)
        let violations = await session.recordedInvariantViolations
        XCTAssertTrue(violations.isEmpty, "表单阻塞/恢复不应破坏 tool_call 良构:\(violations)")
    }

    func testExitReasonsAreRecorded() async {
        // 各退出分支落对应结构化原因码(差距1.3 遥测)。
        // 正常完成
        let s1 = LingShuAgentSession(id: "er1", tools: [], model: Scripted([.text("done")]))
        _ = await s1.send("hi"); let r1 = await s1.lastExitReason
        XCTAssertEqual(r1, .normalCompletion)
        // 基建中断
        let s2 = LingShuAgentSession(id: "er2", tools: [], model: Scripted([.failed(reason: "断网")]))
        _ = await s2.send("hi"); let r2 = await s2.lastExitReason
        XCTAssertEqual(r2, .infraInterrupted)
        // 阻塞
        let ask = LingShuAgentTool(name: "ask_user", description: "问") { _ in "" }
        let s3 = LingShuAgentSession(id: "er3", tools: [ask], model: Scripted([.toolCalls([.init(id: "a", name: "ask_user", argumentsJSON: "{}")])]))
        _ = await s3.send("hi"); let r3 = await s3.lastExitReason
        XCTAssertEqual(r3, .blockedAwaitingInput)
    }
}
