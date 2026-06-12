import Foundation

/// 工具请求：执行专家在产出过程中要求宿主代为执行的真实动作。
struct LingShuToolRequest: Equatable, Sendable {
    var tool: String
    var arguments: [String: String]
}

struct LingShuToolResult: Equatable, Sendable {
    var tool: String
    var success: Bool
    var output: String

    var journalText: String {
        "\(success ? "✓" : "✗") \(tool)：\(String(output.prefix(400)))"
    }
}

/// 工具执行方协议：换沙箱实现、接远程执行器时整体替换（可插拔）。
protocol LingShuToolExecuting: Sendable {
    /// 工具目录说明，拼进执行专家的系统提示。
    var catalogPrompt: String { get }
    func execute(_ request: LingShuToolRequest, workingDirectory: String, allowShell: Bool) async -> LingShuToolResult
}

/// 模型回复中的工具调用行解析：每行 `【工具】{"tool":"...","arguments":{...}}`。
enum LingShuToolCallParser {
    static let marker = "【工具】"

    static func parse(_ reply: String) -> [LingShuToolRequest] {
        reply
            .components(separatedBy: .newlines)
            .compactMap { line -> LingShuToolRequest? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(marker) else { return nil }
                let json = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                guard let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tool = object["tool"] as? String else { return nil }
                let arguments = (object["arguments"] as? [String: Any])?
                    .compactMapValues { $0 as? String } ?? [:]
                return .init(tool: tool, arguments: arguments)
            }
    }

    /// 剥掉工具调用行，留下用户可见正文。
    static func strippingToolLines(_ reply: String) -> String {
        reply
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 本机工具执行器：读/写/列目录限定安全边界，命令执行受权限策略约束，
/// 网络抓取只允许 GET。所有执行结果都会进任务执行记录可审计。
struct LingShuLocalToolExecutor: LingShuToolExecuting {
    var session: URLSession = .shared

    var catalogPrompt: String {
        """
        你可以使用宿主工具完成真实动作。需要时单独输出一行（一行一个调用，可多行）：
        \(LingShuToolCallParser.marker){"tool":"工具名","arguments":{...}}
        宿主会执行并把【工具结果】回传给你，然后你继续产出。可用工具：
        - read_file {"path": "绝对路径"}：读取文本文件（前 8KB）
        - write_file {"path": "绝对路径", "content": "内容"}：写文件（仅限工作目录内）
        - list_directory {"path": "绝对路径"}：列目录
        - fetch_url {"url": "https://…"}：抓取网页/接口文本（GET，前 8KB）
        - run_command {"command": "shell 命令"}：在工作目录执行命令（受权限策略约束，可能被拒绝）
        规则：能用专用工具就不用 run_command；写文件只能写进工作目录；一次最多发 3 个工具调用；
        拿到结果后继续完成交付物，不要把工具调用行留在最终交付物里。
        """
    }

    func execute(_ request: LingShuToolRequest, workingDirectory: String, allowShell: Bool) async -> LingShuToolResult {
        switch request.tool {
        case "read_file":
            return readFile(path: request.arguments["path"] ?? "")
        case "write_file":
            return writeFile(
                path: request.arguments["path"] ?? "",
                content: request.arguments["content"] ?? "",
                workingDirectory: workingDirectory
            )
        case "list_directory":
            return listDirectory(path: request.arguments["path"] ?? "")
        case "fetch_url":
            return await fetchURL(request.arguments["url"] ?? "")
        case "run_command":
            return await runCommand(
                request.arguments["command"] ?? "",
                workingDirectory: workingDirectory,
                allowShell: allowShell
            )
        default:
            return .init(tool: request.tool, success: false, output: "未知工具。可用：read_file / write_file / list_directory / fetch_url / run_command")
        }
    }

    // MARK: - 各工具实现

    /// 读保护：身份档案、钥匙串、SSH 等敏感位置一律拒绝。
    static let deniedReadComponents = [".ssh", ".gnupg", "Keychains", "owner-profile.json", ".aws", "credentials"]

    private func readFile(path: String) -> LingShuToolResult {
        guard path.hasPrefix("/") else {
            return .init(tool: "read_file", success: false, output: "path 必须是绝对路径。")
        }
        guard !Self.deniedReadComponents.contains(where: { path.contains($0) }) else {
            return .init(tool: "read_file", success: false, output: "该位置属于敏感数据，拒绝读取。")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .init(tool: "read_file", success: false, output: "文件不存在或不可读：\(path)")
        }
        let text = String(data: data.prefix(8192), encoding: .utf8) ?? "（非文本文件，\(data.count) 字节）"
        return .init(tool: "read_file", success: true, output: text)
    }

    private func writeFile(path: String, content: String, workingDirectory: String) -> LingShuToolResult {
        let normalizedRoot = (workingDirectory as NSString).standardizingPath
        let normalizedPath = (path as NSString).standardizingPath
        guard normalizedPath.hasPrefix(normalizedRoot + "/") || normalizedPath == normalizedRoot else {
            return .init(tool: "write_file", success: false, output: "写入位置必须在工作目录 \(normalizedRoot) 内。")
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: normalizedPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(toFile: normalizedPath, atomically: true, encoding: .utf8)
            return .init(tool: "write_file", success: true, output: "已写入 \(normalizedPath)（\(content.utf8.count) 字节）")
        } catch {
            return .init(tool: "write_file", success: false, output: "写入失败：\(error.localizedDescription)")
        }
    }

    private func listDirectory(path: String) -> LingShuToolResult {
        guard path.hasPrefix("/") else {
            return .init(tool: "list_directory", success: false, output: "path 必须是绝对路径。")
        }
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: path)
            return .init(tool: "list_directory", success: true, output: entries.sorted().prefix(120).joined(separator: "\n"))
        } catch {
            return .init(tool: "list_directory", success: false, output: "列目录失败：\(error.localizedDescription)")
        }
    }

    private func fetchURL(_ urlText: String) async -> LingShuToolResult {
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .init(tool: "fetch_url", success: false, output: "只支持 http/https URL。")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(8192), encoding: .utf8) ?? "（非文本响应，\(data.count) 字节）"
            return .init(tool: "fetch_url", success: (200..<300).contains(status), output: "HTTP \(status)\n\(text)")
        } catch {
            return .init(tool: "fetch_url", success: false, output: "抓取失败：\(error.localizedDescription)")
        }
    }

    private func runCommand(_ command: String, workingDirectory: String, allowShell: Bool) async -> LingShuToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .init(tool: "run_command", success: false, output: "命令为空。")
        }
        guard allowShell else {
            return .init(tool: "run_command", success: false, output: "当前权限策略要求高风险动作人工确认，命令未执行。请改用专用工具，或由用户在配置中关闭「高风险动作需人工确认」。")
        }
        let lowered = trimmed.lowercased()
        let blocked = ["sudo", "rm -rf /", "mkfs", "diskutil erase", "shutdown", "reboot", "> /dev/"]
        if blocked.contains(where: { lowered.contains($0) }) {
            return .init(tool: "run_command", success: false, output: "命令命中危险操作黑名单，拒绝执行。")
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", trimmed]
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                continuation.resume(returning: .init(tool: "run_command", success: false, output: "启动失败：\(error.localizedDescription)"))
                return
            }

            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(60)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if process.isRunning {
                    process.terminate()
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data.prefix(8192), encoding: .utf8) ?? ""
                let timedOut = Date() >= deadline
                continuation.resume(returning: .init(
                    tool: "run_command",
                    success: process.terminationStatus == 0 && !timedOut,
                    output: timedOut ? "（60s 超时已终止）\n\(output)" : (output.isEmpty ? "（无输出，退出码 \(process.terminationStatus)）" : output)
                ))
            }
        }
    }
}
