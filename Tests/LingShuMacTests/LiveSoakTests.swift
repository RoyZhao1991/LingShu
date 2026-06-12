import XCTest
@testable import LingShuMac

/// 真实泡测：用真实 MiniMax 通道把直答链路与带工具的协同管线整条跑通。
/// 不在常规测试套件里跑（耗时数分钟+真实计费），需显式 LINGSHU_LIVE_SOAK=1 触发。
@MainActor
final class LiveSoakTests: XCTestCase {
    private func requireSoakMode() throws {
        guard ProcessInfo.processInfo.environment["LINGSHU_LIVE_SOAK"] == "1" else {
            throw XCTSkip("仅在 LINGSHU_LIVE_SOAK=1 时运行（真实模型调用）")
        }
    }

    /// 经 security CLI 取 key，避免测试进程直接碰钥匙串 ACL。
    private func liveKey() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "cn.lingshu.model-credentials", "-a", "minimax-official", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let key = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw XCTSkip("钥匙串中没有 MiniMax key") }
        return key
    }

    func testLiveDirectChatRoundTrip() async throws {
        try requireSoakMode()
        let state = LingShuState()
        state.apiKey = try liveKey()
        XCTAssertTrue(state.isModelConnected, "MiniMax 官方通道应已连接")

        let start = Date()
        _ = state.submitTextInput("用一句话介绍你自己", source: .typed)

        var reply: ChatMessage?
        while Date().timeIntervalSince(start) < 90 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let last = state.chatMessages.last, !last.isUser, !last.isLoading, !state.isModelReplying {
                reply = last
                break
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let unwrapped = try XCTUnwrap(reply, "90s 内必须收到直答回复")
        XCTAssertFalse(unwrapped.text.isEmpty)
        XCTAssertTrue(unwrapped.text.contains("灵枢"), "身份口径应是灵枢")
        print("SOAK[直答] \(String(format: "%.1f", elapsed))s ｜ \(unwrapped.text.prefix(100))")
    }

    func testLiveCollaborationPipelineWithTools() async throws {
        try requireSoakMode()
        let state = LingShuState()
        state.apiKey = try liveKey()
        XCTAssertTrue(state.isModelConnected)

        // 完整权限模式：高风险动作不需人工确认（与用户当前设置一致）。
        state.requireHumanApproval = false
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        state.codexWorkingDirectory = workDir.path

        let start = Date()
        let prompt = "写一个 Python 脚本 hello.py：运行时输出今天的日期。把文件保存到工作目录里，并实际运行一次验证输出正常。"
        _ = state.submitTextInput(prompt, source: .typed)

        // 等管线收口（汇报消息出现或记录完结），上限 10 分钟。
        var record: LingShuTaskExecutionRecord?
        while Date().timeIntervalSince(start) < 600 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            record = state.taskExecutionRecords.first { $0.prompt == prompt || $0.title.contains("hello.py") }
            if let record, record.status == .completed || record.status == .blocked || record.status == .answered {
                if !state.isModelExecuting && !state.isModelReplying {
                    break
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let finished = try XCTUnwrap(record, "应能找到本次任务的执行记录")
        print("SOAK[管线] 状态=\(finished.status.rawValue) 耗时=\(String(format: "%.0f", elapsed))s 消息数=\(finished.messages.count)")

        let actors = Set(finished.messages.map(\.actor))
        print("SOAK[管线] 参与方：\(actors.sorted().joined(separator: "、"))")
        for message in finished.messages where message.actor == "工具" {
            print("SOAK[工具] \(message.text.prefix(160))")
        }
        let scriptPath = workDir.appendingPathComponent("hello.py").path
        let fileWritten = FileManager.default.fileExists(atPath: scriptPath)
        print("SOAK[产物] hello.py 落盘=\(fileWritten) 产物清单=\(finished.artifacts.map(\.location))")

        XCTAssertEqual(finished.status, .completed, "管线应完整收口")
        XCTAssertTrue(actors.contains("规划"), "应有真实规划阶段")
        XCTAssertTrue(actors.contains("审议"), "应有真实评审阶段")
        XCTAssertTrue(actors.contains("验证"), "应有真实验收阶段")
        XCTAssertTrue(
            finished.messages.contains { $0.role == "主动汇报" },
            "灵枢必须主动发起完成汇报"
        )
        XCTAssertTrue(
            actors.contains("工具") || fileWritten,
            "完整权限下应有真实工具执行（或至少有文件落盘）"
        )
    }
}
