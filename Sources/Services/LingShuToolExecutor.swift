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
            return readFile(
                path: request.arguments["path"] ?? "",
                offset: request.arguments["offset"].flatMap { Int($0) },
                limit: request.arguments["limit"].flatMap { Int($0) }
            )
        case "write_file":
            return writeFile(
                path: request.arguments["path"] ?? "",
                content: request.arguments["content"] ?? "",
                workingDirectory: workingDirectory
            )
        case "edit_file":
            return editFile(
                path: request.arguments["path"] ?? "",
                oldString: request.arguments["old_string"] ?? "",
                newString: request.arguments["new_string"] ?? "",
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
            return .init(tool: request.tool, success: false, output: "未知工具。可用：read_file / write_file / edit_file / list_directory / fetch_url / run_command")
        }
    }

    // MARK: - 各工具实现

    /// 读保护：身份档案、钥匙串、SSH 等敏感位置一律拒绝。
    static let deniedReadComponents = [".ssh", ".gnupg", "Keychains", "owner-profile.json", ".aws", "credentials"]

    /// 读文件:**按行范围读、带行号、不再 8KB 截断**(编码所必须——大源码文件要能整文件分段看、行号供 edit_file 定位)。
    /// offset=起始行(1 起,默认 1);limit=读多少行(默认 1200,单次封顶防爆上下文);超出范围给提示让模型续读。
    private func readFile(path: String, offset: Int?, limit: Int?) -> LingShuToolResult {
        guard path.hasPrefix("/") else {
            return .init(tool: "read_file", success: false, output: "path 必须是绝对路径。")
        }
        guard !Self.deniedReadComponents.contains(where: { path.contains($0) }) else {
            return .init(tool: "read_file", success: false, output: "该位置属于敏感数据，拒绝读取。")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .init(tool: "read_file", success: false, output: "文件不存在或不可读：\(path)")
        }
        guard let full = String(data: data, encoding: .utf8) else {
            return .init(tool: "read_file", success: true, output: "（非文本文件，\(data.count) 字节）")
        }
        let lines = full.components(separatedBy: "\n")
        let total = lines.count
        let start = max(0, (offset ?? 1) - 1)
        let count = max(1, min(limit ?? 1200, 2000))
        guard start < total else {
            return .init(tool: "read_file", success: true, output: "（文件共 \(total) 行,offset \(start + 1) 已超出末行)")
        }
        let slice = Array(lines.dropFirst(start).prefix(count))
        // cat -n 风格行号(供 edit_file 精确定位);单次输出再按字节封顶 ~80KB。
        var out = ""
        var shown = 0
        for (i, line) in slice.enumerated() {
            let entry = "\(start + i + 1)\t\(line)\n"
            if out.utf8.count + entry.utf8.count > 80_000 { break }
            out += entry
            shown += 1
        }
        let end = start + shown
        let header = (start > 0 || end < total)
            ? "（文件共 \(total) 行,本次显示 \(start + 1)–\(end);要看其余用 offset/limit 续读）\n"
            : ""
        return .init(tool: "read_file", success: true, output: header + out)
    }

    /// 精确编辑:把文件里**唯一匹配**的 old_string 换成 new_string(不重写整文件)——改大代码的核心四肢。
    /// old_string 需与文件内容逐字符一致(含缩进);不唯一/找不到则拒绝并说明,逼模型带足上下文或分次改。
    private func editFile(path: String, oldString: String, newString: String, workingDirectory: String) -> LingShuToolResult {
        let normalizedRoot = (workingDirectory as NSString).standardizingPath
        let normalizedPath = (path as NSString).standardizingPath
        guard normalizedPath.hasPrefix(normalizedRoot + "/") || normalizedPath == normalizedRoot else {
            return .init(tool: "edit_file", success: false, output: "编辑位置必须在工作目录 \(normalizedRoot) 内。")
        }
        guard let data = FileManager.default.contents(atPath: normalizedPath),
              let content = String(data: data, encoding: .utf8) else {
            return .init(tool: "edit_file", success: false, output: "文件不存在或非文本：\(normalizedPath)")
        }
        // 多策略匹配级联(精确→去空白→块锚点→空白归一→缩进灵活):容忍模型缩进/空白小出入,大幅降低"找不到 old_string"误打回。
        switch LingShuEditReplacer.replace(content: content, oldString: oldString, newString: newString) {
        case .replaced(let updated):
            do {
                try updated.write(toFile: normalizedPath, atomically: true, encoding: .utf8)
                return .init(tool: "edit_file", success: true, output: "已编辑 \(normalizedPath)(替换 1 处,现 \(updated.utf8.count) 字节)")
            } catch {
                return .init(tool: "edit_file", success: false, output: "写入失败：\(error.localizedDescription)")
            }
        case .identical:
            return .init(tool: "edit_file", success: false, output: "old_string 与 new_string 相同,无需替换。")
        case .emptyOld:
            return .init(tool: "edit_file", success: false, output: "old_string 不能为空(新建文件请用 write_file)。")
        case .notFound:
            return .init(tool: "edit_file", success: false, output: "没找到 old_string(已尝试精确/去空白/缩进/块锚点等多种匹配仍未命中)。先 read_file 看准再改。")
        case .multiple:
            return .init(tool: "edit_file", success: false, output: "old_string 匹配到多处,不唯一。请带上更多上下文让它唯一,或分多次编辑。")
        case .disproportionate:
            return .init(tool: "edit_file", success: false, output: "匹配到的片段比 old_string 大很多,已拒绝以防误改。请 read_file 看准、给出完整准确的 old_string。")
        }
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

    // 默认 240s：python-pptx 生成、LibreOffice 转 PDF→PNG、pip/brew 装依赖这类真实工程动作常 >60s。
    // 旧的 60s 会把命令砍在半路（"疑似命令未跑完"→产物不落盘）。看门狗那边由执行期续心跳兜住。
    func runCommand(_ command: String, workingDirectory: String, allowShell: Bool, timeout: TimeInterval = 240) async -> LingShuToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .init(tool: "run_command", success: false, output: "命令为空。")
        }
        guard allowShell else {
            return .init(tool: "run_command", success: false, output: "用户已拒绝本次命令执行（授权弹窗选择了拒绝）。请勿重复发起同一命令；改用专用工具，或给出用户可手动运行的方案。")
        }
        let lowered = trimmed.lowercased()
        let blocked = ["sudo", "rm -rf /", "mkfs", "diskutil erase", "shutdown", "reboot", "> /dev/"]
        if blocked.contains(where: { lowered.contains($0) }) {
            return .init(tool: "run_command", success: false, output: "命令命中危险操作黑名单，拒绝执行。")
        }

        return await withCheckedContinuation { continuation in
            let runner = CommandRunner(timeout: timeout)
            runner.start(command: trimmed, workingDirectory: workingDirectory, continuation: continuation)
        }
    }
}

/// run_command 的进程驱动：把可变状态（累积输出、once-resume 标志）收进引用类型，
/// 满足 Swift 6 并发要求，并实现"不依赖 EOF + 超时强制 SIGKILL"的健壮收口。
private final class CommandRunner: @unchecked Sendable {
    private let timeout: TimeInterval
    private let sync = NSLock()
    private let process = Process()
    private var collected = Data()
    private var finished = false
    private var continuation: CheckedContinuation<LingShuToolResult, Never>?

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func start(command: String, workingDirectory: String, continuation: CheckedContinuation<LingShuToolResult, Never>) {
        self.continuation = continuation
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // 关键：关闭 stdin，避免交互式命令（python REPL、cat 无参等）等输入永久卡住。
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading

        // 进程运行期间持续异步读管道，避免缓冲区写满导致子进程阻塞（经典死锁）。
        handle.readabilityHandler = { [weak self] fileHandle in
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.sync.lock()
            if self.collected.count < 8192 { self.collected.append(chunk) }
            self.sync.unlock()
        }

        // 进程退出即收口——不等 EOF，所以孙进程僵死也不会挂起管线。
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                self?.conclude(timedOut: false, handle: handle)
            }
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            resumeOnce(.init(tool: "run_command", success: false, output: "启动失败：\(error.localizedDescription)"))
            return
        }

        // 看门狗：到点强制终止（SIGTERM 后 SIGKILL 兜底）并收口，保证管线绝不无限挂起。
        // 这里强引用 self 保活——runner 是调用方的局部变量，靠这个闭包持有到收口为止。
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            self.sync.lock(); let done = self.finished; self.sync.unlock()
            guard !done else { return }
            if self.process.isRunning {
                self.process.terminate()
                kill(self.process.processIdentifier, SIGKILL)
            }
            self.conclude(timedOut: true, handle: handle)
        }
    }

    private func conclude(timedOut: Bool, handle: FileHandle) {
        sync.lock()
        if finished { sync.unlock(); return }
        finished = true
        let output = collected
        sync.unlock()
        handle.readabilityHandler = nil
        let text = String(data: output.prefix(8192), encoding: .utf8) ?? ""
        let status = process.isRunning ? -1 : process.terminationStatus
        resumeOnce(.init(
            tool: "run_command",
            success: !timedOut && status == 0,
            output: timedOut
                ? "（\(Int(timeout))s 超时已强制终止）\n\(text)"
                : (text.isEmpty ? "（无输出，退出码 \(status)）" : text)
        ))
    }

    private func resumeOnce(_ result: LingShuToolResult) {
        sync.lock()
        let pending = continuation
        continuation = nil
        sync.unlock()
        pending?.resume(returning: result)
    }
}
