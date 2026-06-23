import XCTest
@testable import LingShuMac

/// P3 验收·**用户指定路径 authoritative**(2026-06-23,监工"连文件名都要确认/自建任务被判异常"修):
/// 分类器给 fileExists 编占位名(fibonacci_output.txt)与用户原话路径不符 → 真文件被判未找到 → 无尽返工/反问。
/// 修:fileExists 探针对齐到用户明确指定的输出路径。
@MainActor
final class AcceptanceFileProbeReconcileTests: XCTestCase {

    private func record(prompt: String, constraints: [String], criteria: [String]) -> LingShuTaskExecutionRecord {
        var r = LingShuTaskExecutionRecord(id: "r1", title: "t", prompt: prompt, status: .running, summary: "",
                                           participants: [], createdAt: Date(), updatedAt: Date(), messages: [])
        r.goalSpec = LingShuGoalSpec(objective: "生成脚本保存到指定文件", kind: .task,
                                     constraints: constraints, successCriteria: criteria)
        return r
    }

    func testHallucinatedProbeReconciledToUserPath() {
        let state = LingShuState()
        state.taskExecutionRecords = [record(prompt: "写脚本保存到 /tmp/lingshu_soak/fib_59.txt",
                                             constraints: ["输出文件路径必须为 /tmp/lingshu_soak/fib_59.txt"],
                                             criteria: ["结果以可读格式写入指定文件"])]
        XCTAssertTrue(state.userSpecifiedOutputPaths(taskRecordID: "r1").contains("/tmp/lingshu_soak/fib_59.txt"))
        let checks = [LingShuAcceptanceCheck(kind: .fileExists, criterion: "结果以可读格式写入指定文件", probe: "fibonacci_output.txt")]
        let out = state.reconcileFileProbesToUserPaths(checks, taskRecordID: "r1")
        XCTAssertEqual(out[0].probe, "/tmp/lingshu_soak/fib_59.txt", "占位名→换成用户指定路径(不再误判失败/反问)")
    }

    func testProbeAlreadyMatchingUserPathUntouched() {
        let state = LingShuState()
        state.taskExecutionRecords = [record(prompt: "存到 /tmp/x/out.txt", constraints: ["输出到 /tmp/x/out.txt"], criteria: ["写入 out.txt"])]
        let checks = [LingShuAcceptanceCheck(kind: .fileExists, criterion: "写入 out.txt", probe: "/tmp/x/out.txt")]
        XCTAssertEqual(state.reconcileFileProbesToUserPaths(checks, taskRecordID: "r1")[0].probe, "/tmp/x/out.txt", "已对上的不动")
        // basename 对上也不动
        let c2 = [LingShuAcceptanceCheck(kind: .fileExists, criterion: "x", probe: "out.txt")]
        XCTAssertEqual(state.reconcileFileProbesToUserPaths(c2, taskRecordID: "r1")[0].probe, "out.txt", "basename 对上→不动")
    }

    func testNonFileChecksAndNoUserPathUntouched() {
        let state = LingShuState()
        // 用户没指定路径 → 不强改。
        state.taskExecutionRecords = [record(prompt: "写个斐波那契脚本", constraints: [], criteria: ["脚本能跑通"])]
        let cmd = [LingShuAcceptanceCheck(kind: .commandSucceeds, criterion: "脚本能跑通", probe: "python")]
        XCTAssertEqual(state.reconcileFileProbesToUserPaths(cmd, taskRecordID: "r1")[0].probe, "python", "非 fileExists 不动")
        let fe = [LingShuAcceptanceCheck(kind: .fileExists, criterion: "x", probe: "anything.txt")]
        XCTAssertEqual(state.reconcileFileProbesToUserPaths(fe, taskRecordID: "r1")[0].probe, "anything.txt", "无用户路径→不强改")
    }
}
