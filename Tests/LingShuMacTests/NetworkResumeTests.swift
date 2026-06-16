import XCTest
@testable import LingShuMac

/// 断网重连自动续跑:基础设施故障(网关不可达)被识别成 `.interrupted`(非任务失败),
/// 上下文原样保留,`continueLoop()` 从中断处续上;编排器把它标「已暂停」并保留会话,`resumeInterrupted` 重连续跑。
final class NetworkResumeTests: XCTestCase {

    /// 第 1 次模型调用返回基础设施故障 `.failed`,之后正常返回文本(模拟断网→重连)。
    private final class FailThenSucceed: LingShuAgentModel, @unchecked Sendable {
        private(set) var calls = 0
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            calls += 1
            return calls == 1 ? .failed(reason: "似乎已断开与互联网的连接") : .text("网络恢复,已续跑完成")
        }
    }

    // MARK: 循环级:.failed → .interrupted,不污染上下文,continueLoop 续上

    func testInfraFailureBecomesInterruptedAndPreservesContext() async {
        let model = FailThenSucceed()
        let session = LingShuAgentSession(id: "net", tools: [], model: model)

        let first = await session.send("做个会断网的任务")
        // 基础设施故障 → .interrupted(非 .completed / 非 .maxTurnsReached)。
        XCTAssertEqual(first, .interrupted(reason: "似乎已断开与互联网的连接"))
        // 上下文未被污染:最后一条仍是用户输入,**没有**追加假的"调用失败"助手消息——续跑才能干净接上。
        let mid = await session.messages
        XCTAssertEqual(mid.last?.role, .user)
        XCTAssertEqual(mid.last?.content, "做个会断网的任务")
        XCTAssertFalse(mid.contains { $0.role == .assistant }, "中断不应留下任何助手消息")

        // 重连:从中断处 continueLoop()(不注入新消息),应正常收尾。
        let resumed = await session.continueLoop()
        XCTAssertEqual(resumed, .completed(text: "网络恢复,已续跑完成"))
    }

    // MARK: 编排器级:中断→已暂停(非失败,保留会话)→ resumeInterrupted → 完成

    private func ledgerStatus(_ orch: LingShuAgentOrchestrator, _ id: String) async -> LingShuLedgerStatus? {
        await orch.ledger().first(where: { $0.id == id })?.status
    }

    private func waitFor(_ orch: LingShuAgentOrchestrator, _ id: String, _ target: LingShuLedgerStatus, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await ledgerStatus(orch, id) == target { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await ledgerStatus(orch, id) == target
    }

    func testDispatchedTaskSuspendsOnInfraFailureThenAutoResumes() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        await orch.setAcceptanceHook { @MainActor _, _, _, initial in initial }   // 透传(隔离验收逻辑)
        let model = FailThenSucceed()
        let sub = LingShuAgentSession(id: "sub-net", tools: [], model: model)

        let admitted = await orch.spawnDetached(id: "sub-net", objective: "会断网的子任务", session: sub)
        XCTAssertTrue(admitted)

        // 断网 → 标「已暂停」(非「已失败」),会话保留,登记进 suspendedIDs。
        let didSuspend = await waitFor(orch, "sub-net", .suspended)
        XCTAssertTrue(didSuspend, "网络中断应记为 suspended,而非 failed")
        let suspended = await orch.suspendedIDs()
        XCTAssertEqual(suspended, ["sub-net"])

        // 重连:resumeInterrupted → continueLoop 续跑 → 完成。
        await orch.resumeInterrupted(id: "sub-net")
        let didComplete = await waitFor(orch, "sub-net", .completed)
        XCTAssertTrue(didComplete, "重连后应自动续跑到完成")
        let stillSuspended = await orch.suspendedIDs()
        XCTAssertTrue(stillSuspended.isEmpty, "完成后应从暂停集合移除")
        let summary = await orch.ledger().first(where: { $0.id == "sub-net" })?.summary
        XCTAssertEqual(summary?.contains("网络恢复,已续跑完成"), true)
    }

    /// 手动「继续」(resumeWithInput)也能续跑隔离会话(Phase 4)。
    func testManualResumeWithInputContinuesIsolatedSession() async {
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        await orch.setAcceptanceHook { @MainActor _, _, _, initial in initial }
        let model = FailThenSucceed()
        let sub = LingShuAgentSession(id: "sub-manual", tools: [], model: model)
        _ = await orch.spawnDetached(id: "sub-manual", objective: "断网后手动继续", session: sub)
        let didSuspend = await waitFor(orch, "sub-manual", .suspended)
        XCTAssertTrue(didSuspend)

        // 用户在窗口点「继续」→ resumeWithInput,把输入喂给这条隔离会话(它才有上下文)。
        let result = await orch.resumeWithInput(id: "sub-manual", input: "继续")
        if case .completed = result {} else { XCTFail("手动继续应续跑到完成,实际:\(String(describing: result))") }
        let finalStatus = await ledgerStatus(orch, "sub-manual")
        XCTAssertEqual(finalStatus, .completed)
    }
}
