import XCTest
@testable import LingShuMac

/// 执行恢复力:验证「能跑通/不崩」运行门的识别逻辑(纯 helper)+ 编排器把子任务验收/恢复
/// 委托给统一 verifyAndContinue(撞顶不再直接判失败,而是经 acceptanceHook 续跑恢复)。
final class ExecutionResilienceTests: XCTestCase {

    // MARK: - 运行门:构建/运行命令识别

    func testBuildOrRunCommandDetection() {
        // 构建/运行程序本身 → 命中。
        for cmd in ["swift build", "swift run mygame", "python3 game.py", "python app.py",
                    "node server.js", "go build ./...", "go run main.go", "cargo run",
                    "make ", "gcc main.c -o app", "clang++ a.cpp", "./game", "npm run build",
                    "javac Main.java && java Main"] {
            XCTAssertTrue(LingShuState.looksLikeBuildOrRunCommand(cmd.lowercased()), "应识别为构建/运行:\(cmd)")
        }
        // 纯读 / 查 / 装依赖 → 不命中。
        for cmd in ["ls -la", "cat readme.md", "grep -rn foo src", "git status",
                    "find . -name '*.py'", "pip install pytest", "echo hi"] {
            XCTAssertFalse(LingShuState.looksLikeBuildOrRunCommand(cmd.lowercased()), "不应识别为构建/运行:\(cmd)")
        }
    }

    func testTestCommandsAreExcludedFromRunGateClassification() {
        // 测试运行器归测试门,不算"运行程序本身"(在 codeTaskRunEvidence 里以 !looksLikeTestCommand 排除)。
        // 这里直接验证这些命令确实被 looksLikeTestCommand 命中,从而在运行门里被排除。
        for cmd in ["swift test", "go test ./...", "python -m pytest -q", "npm test", "cargo test"] {
            XCTAssertTrue(LingShuState.looksLikeTestCommand(cmd.lowercased()), "应识别为测试命令(运行门排除):\(cmd)")
        }
    }

    // MARK: - 运行门:崩溃签名识别

    func testCrashSignatureDetection() {
        // 高置信崩溃/构建失败签名 → 命中。
        for out in ["Traceback (most recent call last):\n  File ...", "Segmentation fault: 11",
                    "fatal error: 'foo.h' file not found", "thread panicked: panic: index out of range",
                    "BUILD FAILED", "ModuleNotFoundError: No module named 'x'",
                    "Undefined reference to `main'", "Compilation failed", "command not found: python4"] {
            XCTAssertTrue(LingShuState.outputLooksLikeCrash(out), "应识别为崩溃/失败:\(out)")
        }
        // 正常输出 → 不误判(尤其别因泛泛的字眼炸)。
        for out in ["Build complete! (1.2s)", "All tests passed", "Compiling LingShu...",
                    "10 passed in 0.3s", "Done. 0 errors.", "Server listening on :8080"] {
            XCTAssertFalse(LingShuState.outputLooksLikeCrash(out), "正常输出不应判崩溃:\(out)")
        }
    }

    func testCrashSnippetExtractsAroundSignature() {
        let output = """
        compiling...
        loading assets
        Traceback (most recent call last):
          File "game.py", line 42, in <module>
        IndexError: list index out of range
        """
        let snippet = LingShuState.crashSnippet(from: output)
        XCTAssertTrue(snippet.contains("Traceback") || snippet.contains("IndexError"),
                      "崩溃片段应围绕签名行,实际:\(snippet)")
        XCTAssertFalse(snippet.contains("compiling..."), "不该把无关的开头行也带进来")
    }

    // MARK: - 编排器:撞顶委托给 acceptanceHook 恢复(不再直接判失败)

    /// 按序返回脚本响应的 mock 模型。
    private final class Scripted: LingShuAgentModel, @unchecked Sendable {
        private let script: [LingShuAgentModelResponse]
        private var index = 0
        init(_ s: [LingShuAgentModelResponse]) { script = s }
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            defer { index += 1 }
            return index < script.count ? script[index] : .text("(脚本耗尽)")
        }
    }

    private func waitForTerminal(_ orch: LingShuAgentOrchestrator, id: String, timeout: TimeInterval = 3) async -> LingShuLedgerStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = await orch.ledger().first(where: { $0.id == id })?.status,
               status != .running { return status }
            try? await Task.sleep(nanoseconds: 20_000_000)   // 20ms
        }
        return await orch.ledger().first(where: { $0.id == id })?.status
    }

    func testDriveDelegatesRecoveryViaAcceptanceHook() async {
        // 子会话先撞顶(maxTurns=2,前两轮都是工具调用永不收尾)→ acceptanceHook 模拟"撞顶续跑恢复":
        // resume 一次后模型给出最终文本 → 结果应是 completed,账本记 completed(而非旧路径的直接 failed=异常)。
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        await orch.setAcceptanceHook { @MainActor _, _, session, initial in
            if case .maxTurnsReached = initial {
                return await session.resume("撞顶续跑:继续把它做完")
            }
            return initial
        }
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "ok" }
        let model = Scripted([
            .toolCalls([.init(id: "c1", name: "noop", argumentsJSON: "{}")]),
            .toolCalls([.init(id: "c2", name: "noop", argumentsJSON: "{}")]),
            .text("已修好并完成"),   // resume 后这一轮收尾
        ])
        let sub = LingShuAgentSession(id: "sub-recover", tools: [noop], model: model, maxTurns: 2)

        let admitted = await orch.spawnDetached(id: "sub-recover", objective: "做个会撞顶的复杂任务", session: sub)
        XCTAssertTrue(admitted)
        let status = await waitForTerminal(orch, id: "sub-recover")
        XCTAssertEqual(status, .completed, "撞顶后经 acceptanceHook 恢复应记 completed,而非直接 failed")
        let summary = await orch.ledger().first(where: { $0.id == "sub-recover" })?.summary
        XCTAssertEqual(summary?.contains("已修好并完成"), true)
    }

    func testDriveHonestFailWhenHookCannotRecover() async {
        // 对照:acceptanceHook 原样透传撞顶(模拟恢复后仍未收尾)→ 诚实记 failed。
        let orch = LingShuAgentOrchestrator(maxConcurrent: 3)
        await orch.setAcceptanceHook { @MainActor _, _, _, initial in initial }   // 不恢复,透传
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "ok" }
        let model = Scripted(Array(repeating: .toolCalls([.init(id: "c", name: "noop", argumentsJSON: "{}")]), count: 10))
        let sub = LingShuAgentSession(id: "sub-fail", tools: [noop], model: model, maxTurns: 2)

        _ = await orch.spawnDetached(id: "sub-fail", objective: "撞顶且无法恢复", session: sub)
        let status = await waitForTerminal(orch, id: "sub-fail")
        XCTAssertEqual(status, .failed, "恢复无效时应诚实记 failed")
    }
}
