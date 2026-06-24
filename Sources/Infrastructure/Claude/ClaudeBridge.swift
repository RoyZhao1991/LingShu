import Foundation

/// Claude Code CLI 桥(`claude -p` 非交互)——把 Claude Code 当一个可委托的**外部 agent 工具**。
/// 与 CodexBridge 同构:解析 CLI、判可用、一次性跑目标返回结果文本。阻塞,调用方放后台线程;取消复用 `CodexExecutionHandle`。
enum ClaudeReplyResult: Sendable { case success(String); case failure(String) }

enum ClaudeBridge {
    static let candidatePaths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]

    static func resolveCLIPath(preferredPath: String = "") -> String? {
        ([preferredPath] + candidatePaths).first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 是否可用(装了 claude CLI)。登录态由 claude 自身管,不在此判(未登录会在 exec 时失败)。
    static func isAvailable(preferredPath: String = "") -> Bool { resolveCLIPath(preferredPath: preferredPath) != nil }

    /// `claude -p` 非交互完成一个目标,返回结果文本。**阻塞**——调用方放后台线程。
    /// permissionMode 默认 bypassPermissions(委托的编码 agent 要能真改文件/跑命令;dev 阶段全权下合理,可收紧)。
    static func execReply(
        preferredPath: String = "",
        prompt: String,
        workingDirectory: String,
        timeout: TimeInterval,
        permissionMode: String = "bypassPermissions",
        cancellation: CodexExecutionHandle? = nil
    ) -> ClaudeReplyResult {
        guard let cli = resolveCLIPath(preferredPath: preferredPath) else {
            return .failure("没有找到 Claude Code CLI(claude)。请确认已安装(brew/官方)并登录。")
        }
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = trimmed.isEmpty ? FileManager.default.currentDirectoryPath : trimmed
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .failure("目标项目目录不存在:\(dir)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-p", prompt, "--permission-mode", permissionMode, "--output-format", "text"]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)

        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe

        // 后台并发排空两个管道(readDataToEndOfFile 阻塞到管道关闭=进程退出/被终止),避免缓冲区满 → 写阻塞死锁。
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        var outData = Data(); var errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global(qos: .userInitiated).async { outData = outHandle.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global(qos: .userInitiated).async { errData = errHandle.readDataToEndOfFile(); group.leave() }

        cancellation?.attach(process)
        do { try process.run() } catch {
            return .failure("启动 claude 失败:\(error.localizedDescription)")
        }

        // 超时看门狗:轮询 isRunning,超时则终止(终止使管道关闭 → 上面的 drain 退出)。
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline { timedOut = true; process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        process.waitUntilExit()
        group.wait()
        cancellation?.detach(process)

        let out = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let err = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if cancellation?.isCancelled == true { return .failure("Claude CLI 调用已取消。") }
        if timedOut { return .failure("Claude CLI 超时(\(Int(timeout))s 无完成)。") }
        if process.terminationStatus == 0 {
            return .success(out.isEmpty ? "(Claude 完成,无文本输出)" : out)
        }
        return .failure(err.isEmpty ? "Claude CLI 退出码 \(process.terminationStatus)。\(out.prefix(400))" : err)
    }
}
