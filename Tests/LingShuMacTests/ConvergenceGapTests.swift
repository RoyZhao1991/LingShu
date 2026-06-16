import XCTest
@testable import LingShuMac

/// 两个收敛缺口的修复(超级玛丽任务暴露):
/// ① maker 过度自测不收尾 → 已产出文件后连续多步只测试/查看 → 强制收尾交独立验收;
/// ② 派发隔离 session 没法 interject → 编排器可把纠正注入子会话。
final class ConvergenceGapTests: XCTestCase {

    // MARK: ① 过度自测收敛

    /// 写一次文件后,不停跑测试(每次参数不同,绕过 stuck 检测)空转 → 应在 overValidationForceAt 处强制收尾。
    func testOverValidationForcesCompletion() async {
        final class WriteThenSpin: LingShuAgentModel, @unchecked Sendable {
            var n = 0
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                n += 1
                if n == 1 {
                    return .toolCalls([.init(id: "w", name: "write_file", argumentsJSON: "{\"path\":\"game.js\"}")])
                }
                // 每次参数不同 → 绕过"完全相同"的 stuck 检测,模拟 node test 反复跑
                return .toolCalls([.init(id: "r\(n)", name: "run_command", argumentsJSON: "{\"command\":\"node test.js #\(n)\"}")])
            }
        }
        let model = WriteThenSpin()
        let wf = LingShuAgentTool(name: "write_file", description: "写") { _ in "written" }
        let rc = LingShuAgentTool(name: "run_command", description: "跑") { _ in "56 passed, 0 failed" }
        // 高 maxTurns:证明是"收敛门"触发,而非撞天花板。
        let session = LingShuAgentSession(id: "ov", tools: [wf, rc], model: model, maxTurns: 300)
        let result = await session.send("做个游戏")

        guard case .completed = result else { return XCTFail("过度自测应强制收尾为 .completed(交独立验收),实际:\(result)") }
        let used = await session.turnsUsed
        XCTAssertEqual(used, 1 + LingShuAgentSession.overValidationForceAt, "写1次 + ForceAt 次无改动后强制收尾")
        XCTAssertLessThan(used, 300, "是收敛门触发,不是撞 maxTurns")
    }

    /// 持续有真进展(周期性改文件)→ 绝不被过度自测门误伤,正常按 .text 收尾。
    func testProgressingTaskNotForcedPrematurely() async {
        final class WriteRunThenDone: LingShuAgentModel, @unchecked Sendable {
            var n = 0
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                n += 1
                if n >= 9 { return .text("做完了,产出物已落盘") }
                // 写、跑、写、跑…… 每隔一步就改文件 → turnsSinceMutation 永远到不了门槛
                return n % 2 == 1
                    ? .toolCalls([.init(id: "w\(n)", name: "write_file", argumentsJSON: "{\"path\":\"f\(n).js\"}")])
                    : .toolCalls([.init(id: "r\(n)", name: "run_command", argumentsJSON: "{\"command\":\"node test #\(n)\"}")])
            }
        }
        let model = WriteRunThenDone()
        let wf = LingShuAgentTool(name: "write_file", description: "写") { _ in "ok" }
        let rc = LingShuAgentTool(name: "run_command", description: "跑") { _ in "pass" }
        let session = LingShuAgentSession(id: "prog", tools: [wf, rc], model: model, maxTurns: 300)
        let result = await session.send("做")
        XCTAssertEqual(result, .completed(text: "做完了,产出物已落盘"), "持续有进展的任务不应被过度自测门强制收尾")
    }

    // MARK: ② 派发隔离 session 可被纠偏

    func testOrchestratorInjectsCorrectionIntoIsolatedSession() async {
        final class CorrAware: LingShuAgentModel, @unchecked Sendable {
            var step = 0
            private(set) var sawCorrection = false
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .user && $0.content.contains("改用方案B") }) {
                    sawCorrection = true
                    return .text("已按纠正改用方案B")
                }
                step += 1
                if step == 1 { return .toolCalls([.init(id: "q", name: "ask_user", argumentsJSON: "{\"question\":\"A还是B?\"}")]) }
                return .text("默认A")
            }
        }
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        let model = CorrAware()
        let sub = LingShuAgentSession(id: "sub-c", tools: [], model: model)
        let first = await orch.spawn(id: "sub-c", objective: "做", session: sub)   // 卡在 ask_user
        XCTAssertEqual(first, .blocked(question: "A还是B?"))

        // 把纠正注入这条**隔离子会话**(主/自主会话的 interject 够不到它)。
        _ = await orch.injectCorrection(id: "sub-c", "改用方案B")
        let resumed = await orch.resume(id: "sub-c", answer: "A")
        XCTAssertEqual(resumed, .completed(text: "已按纠正改用方案B"), "续跑应采纳注入到隔离子会话的纠正")
        XCTAssertTrue(model.sawCorrection)
    }
}
