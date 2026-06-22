import Foundation

/// 工作区「终端」模式的命令执行器(基础设施层——视图不直接碰 `Process`)。
/// 在 `cwd` 下用 zsh 跑一条命令,合并 stdout+stderr;尾随回报最终 pwd(让 `cd` 跨命令保持)。
/// 非交互式(无 PTY):一次性命令 OK;`timeout` 上限防交互/卡死程序永久挂起。
enum LingShuTerminalShell {
    static func run(cmd: String, cwd: String, timeout: TimeInterval = 120) async -> (output: String, newPwd: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.arguments = ["-lc", "{ \(cmd) ; } 2>&1 ; printf '\\n__LSPWD__:%s' \"$(pwd)\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ("zsh 启动失败:\(error.localizedDescription)", nil) }
        let killer = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if p.isRunning { p.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        var text = String(data: data, encoding: .utf8) ?? ""
        var newPwd: String?
        if let r = text.range(of: "__LSPWD__:", options: .backwards) {
            newPwd = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[..<r.lowerBound])
        }
        while text.hasSuffix("\n") { text.removeLast() }
        return (text, newPwd)
    }
}
