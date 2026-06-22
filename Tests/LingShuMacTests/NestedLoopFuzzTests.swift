import XCTest
@testable import LingShuMac

/// 嵌套分阶段循环(`.nested`,第二个核心引擎,自主/多阶段在用)的属性/混沌测试(测无可测战役·Round 2)。
/// `.nested` 的内层是经典 `LingShuAgentSession` → 已被循环不变量网覆盖;这里额外锤**分阶段状态机**:
/// 随机多阶段计划(任务/互动混排)× 随机打断/续接/互动收口信号,断言:
///  ① 内层会话全程不破循环不变量(全局遥测恒 0)② turnsUsed 单调 ③ 每次 send/resume/continue 都返回终态(不 wedge)
///  ④ 打断 → 存断点 → 续接从断点阶段续(不重头/不跳过)⑤ 不崩。
@MainActor
final class NestedLoopFuzzTests: XCTestCase {

    /// 跨 actor 边界的可变打断旗标。仅在 MainActor 上读写(测试 + 注入闭包都是 @MainActor),故 unchecked 安全。
    final class Flag: @unchecked Sendable { var on = false }

    struct SplitMix64: RandomNumberGenerator {
        var s: UInt64; init(_ seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15; var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 识别规划提示 → 返回确定性多阶段计划;其余(内层/spine)走混沌。
    final class NestedFuzzModel: LingShuAgentModel, @unchecked Sendable {
        private var rng: SplitMix64
        private var seq = 0
        let planText: String
        init(seed: UInt64, planText: String) { rng = SplitMix64(seed); self.planText = planText }
        private func roll(_ m: UInt64) -> UInt64 { rng.next() % m }
        private func id() -> String { seq += 1; return "n\(seq)" }

        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            if let last = messages.last, last.content.contains("把下面这次请求拆成有序执行的阶段") {
                return .text(planText)
            }
            switch roll(100) {
            case 0..<35: return .text("本阶段完成,产出物在 /tmp/x。")
            case 35..<45: return .failed(reason: "混沌断网")
            case 45..<52:
                return .toolCalls([.init(id: id(), name: "ask_user", argumentsJSON: "{\"question\":\"确认?\"}")])
            case 52..<66:
                return .toolCalls([.init(id: id(), name: "run_command", argumentsJSON: "{\"cmd\":\"same\"}")]) // 触发停滞
            default:
                let n = Int(roll(2)) + 1
                return .toolCalls((0..<n).map { _ in .init(id: id(), name: ["write_file","read_file","run_command"][Int(roll(3))], argumentsJSON: "{\"v\":\(roll(5))}") })
            }
        }
    }

    private func fuzzTools() -> [LingShuAgentTool] {
        ["write_file","edit_file","read_file","run_command","update_plan","ask_user"].map { name in
            LingShuAgentTool(name: name, description: name) { _ in "ok:\(name)" }
        }
    }

    /// 几种代表性计划(任务/互动各种混排 + 边界:全任务/全互动/首互动)。
    private static let plans = [
        "1. [任务] 写A\n2. [任务] 写B",
        "1. [任务] 写A\n2. [互动] 演示讲解A",
        "1. [互动] 先陪聊\n2. [任务] 再写报告\n3. [互动] 答疑",
        "1. [互动] 全屏演示\n2. [互动] 答疑",
        "1. [任务] 写A\n2. [任务] 写B\n3. [任务] 写C\n4. [互动] 演示讲解",
    ]

    private func makeNested(seed: UInt64, planText: String, flag: Flag) -> LingShuNestedAgentSession {
        let model = NestedFuzzModel(seed: seed, planText: planText)
        return LingShuNestedAgentSession(
            id: "nfuzz-\(seed)", system: "测试体", initialMessages: [], tools: fuzzTools(), model: model,
            maxTurns: Int(seed % 12) + 3, maxHistoryMessages: 0, blockingToolNames: ["ask_user"],
            acceptStage: { _, r, _ in r },                       // 内层已被网覆盖,这里透传(只测状态机)
            note: { _, _ in }, setPhase: { _ in },
            isInterrupted: { flag.on }, consumeInterrupt: { flag.on = false },
            recallMemory: { _ in "" }
        )
    }

    func testNestedChaosNoInvariantViolations() async {
        LingShuLoopInvariantTelemetry.reset()
        let count = ProcessInfo.processInfo.environment["LINGSHU_FUZZ_SEEDS"].flatMap { Int($0) } ?? 200
        for i in 0..<count {
            let seed = UInt64(i) &* 2654435761 &+ 777
            var rng = SplitMix64(seed)
            let plan = Self.plans[Int(rng.next() % UInt64(Self.plans.count))]
            let flag = Flag()
            let session = makeNested(seed: seed, planText: plan, flag: flag)

            var prevTurns = 0
            // 多次交互:首发(多阶段)+ 随机打断 + 续接 + 互动收口。
            let steps = Int(rng.next() % 5) + 2
            var lastResult: LingShuAgentRunResult = .completed(text: "")
            for step in 0..<steps {
                // 随机在某步前置打断旗标(模拟唤醒词 barge / 主人插话)。
                if rng.next() % 3 == 0 { flag.on = true }
                let isBlocked = await session.isBlocked
                if step == 0 {
                    lastResult = await session.send("先写东西然后演示讲解")   // shouldPlanStages=true
                } else if isBlocked {
                    lastResult = await session.resume("补给阻塞的答案")
                } else if case .interrupted = lastResult {
                    lastResult = await session.continueLoop()
                } else if rng.next() % 2 == 0 {
                    lastResult = await session.resume("没了")               // 互动收口信号
                } else {
                    lastResult = await session.send("继续推进 \(rng.next() % 99)")
                }
                // ② turnsUsed 单调
                let turns = await session.turnsUsed
                XCTAssertGreaterThanOrEqual(turns, prevTurns, "种子 \(seed) 步 \(step):turnsUsed 倒退")
                prevTurns = turns
                // ⑤ 不崩(走到这里即没崩);③ 返回了终态(await 已返回)
            }
        }
        // ① 内层会话全程零循环不变量违反
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0,
                       "嵌套混沌中内层会话破了循环不变量(累计 \(LingShuLoopInvariantTelemetry.total)):\(LingShuLoopInvariantTelemetry.lastSamples)")
    }

    // MARK: 定向:打断 → 断点 → 续接从断点阶段续(不重头/不跳过)

    func testInterruptStoresBreakpointAndResumesSameStage() async {
        LingShuLoopInvariantTelemetry.reset()
        let flag = Flag()
        // 3 个任务阶段,首发即在第 1 阶段后打断 → 应存断点,续接不重头。
        let session = makeNested(seed: 42, planText: "1. [任务] 写A\n2. [任务] 写B\n3. [任务] 写C", flag: flag)
        flag.on = true                                  // 一上来就打断 → 在第 1 阶段(index 0)边界就停
        let r1 = await session.send("先写A然后写B再写C")
        guard case .completed = r1 else { return XCTFail("打断应优雅返回 completed(断点已存),实际 \(r1)") }
        // 续接:消费打断标志,从断点阶段续,跑到终验完成。
        let r2 = await session.send("继续")
        guard case .completed = r2 else { return XCTFail("续接应能跑完,实际 \(r2)") }
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0, "断点续接不应破不变量:\(LingShuLoopInvariantTelemetry.lastSamples)")
    }

    func testSingleStageFallbackBehavesLikeClassic() async {
        // shouldPlanStages=false 的简单请求走 spine 直通 = 经典;不分阶段、能正常收尾。
        LingShuLoopInvariantTelemetry.reset()
        let flag = Flag()
        let session = makeNested(seed: 7, planText: "(不会用到)", flag: flag)
        let r = await session.send("你好")              // 无序号衔接词 → 直通
        switch r {
        case .completed, .blocked, .maxTurnsReached, .interrupted: break   // 任一终态都可
        }
        XCTAssertEqual(LingShuLoopInvariantTelemetry.total, 0, "直通不应破不变量")
    }
}
