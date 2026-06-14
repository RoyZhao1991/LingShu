import Foundation

/// Codex 登录(device-auth)操作子域:从 LingShuState 主文件拆出,保持主文件聚焦。
@MainActor
extension LingShuState {
    func openCodexLogin() {
        let cliPath = CodexBridge.resolveCLIPath(preferredPath: codexCLIPath) ?? CodexBridge.bundledCLIPath
        let command = "\"\(cliPath)\" login --device-auth"
        let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            logEvent("现在  已打开 Codex 登录终端，请按提示完成 ChatGPT 授权。")
            appendTrace(kind: .tool, actor: "Codex Auth", title: "打开登录", detail: "已启动 Codex device auth 登录终端。")
        } catch {
            logEvent("现在  打开 Codex 登录失败：\(error.localizedDescription)。")
            appendTrace(kind: .warning, actor: "Codex Auth", title: "登录失败", detail: error.localizedDescription)
        }
    }
}
