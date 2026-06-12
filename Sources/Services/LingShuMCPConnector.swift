import Foundation

/// MCP 连接器配置：一个外部 MCP server（stdio 启动）。配置存
/// ~/Library/Application Support/LingShu/Connectors/servers.json。
struct LingShuMCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var command: String
    var arguments: [String]
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, command: String, arguments: [String] = [], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.enabled = enabled
    }
}

/// 一个 MCP server 暴露的工具描述。
struct LingShuMCPToolDescriptor: Equatable, Sendable {
    var serverID: String
    var serverName: String
    var name: String
    var description: String
}

/// 极简 MCP stdio 客户端：按 JSON-RPC 2.0 over stdio 与 server 通讯，
/// 支持 initialize / tools/list / tools/call。每次调用起一个短生命周期进程
/// （一发一收一退），不维持常驻连接——足够把外部 MCP 工具接进协同管线，
/// 且不引入连接管理复杂度。后续要常驻双工可在此类内升级，对外合同不变。
final class LingShuMCPStdioClient: @unchecked Sendable {
    private let config: LingShuMCPServerConfig
    private let timeout: TimeInterval

    init(config: LingShuMCPServerConfig, timeout: TimeInterval = 30) {
        self.config = config
        self.timeout = timeout
    }

    /// 列出 server 暴露的工具。
    func listTools() async -> [LingShuMCPToolDescriptor] {
        let frames = [
            initializeFrame(id: 1),
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]
        ]
        guard let responses = await exchange(frames) else { return [] }
        for response in responses {
            guard (response["id"] as? Int) == 2,
                  let result = response["result"] as? [String: Any],
                  let tools = result["tools"] as? [[String: Any]] else { continue }
            return tools.compactMap { tool in
                guard let name = tool["name"] as? String else { return nil }
                return LingShuMCPToolDescriptor(
                    serverID: config.id,
                    serverName: config.name,
                    name: name,
                    description: (tool["description"] as? String) ?? ""
                )
            }
        }
        return []
    }

    /// 调用一个工具，返回文本结果。
    func callTool(name: String, arguments: [String: Any]) async -> LingShuToolResult {
        let frames: [[String: Any]] = [
            initializeFrame(id: 1),
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        ]
        guard let responses = await exchange(frames) else {
            return .init(tool: "mcp:\(name)", success: false, output: "MCP server \(config.name) 无响应或启动失败。")
        }
        for response in responses where (response["id"] as? Int) == 3 {
            if let error = response["error"] as? [String: Any] {
                return .init(tool: "mcp:\(name)", success: false, output: "MCP 错误：\(error["message"] as? String ?? "未知")")
            }
            if let result = response["result"] as? [String: Any] {
                let text = Self.extractText(from: result)
                let isError = (result["isError"] as? Bool) ?? false
                return .init(tool: "mcp:\(name)", success: !isError, output: text.isEmpty ? "（无文本结果）" : text)
            }
        }
        return .init(tool: "mcp:\(name)", success: false, output: "MCP server \(config.name) 未返回 tools/call 结果。")
    }

    // MARK: - 内部

    private func initializeFrame(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "LingShu", "version": "1.0"]
            ]
        ]
    }

    static func extractText(from result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block -> String? in
            if (block["type"] as? String) == "text" { return block["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    /// 起进程，写入所有请求帧（每行一个 JSON），读取原始 stdout，按行解析成 JSON 对象。
    /// 进程驱动只回传 Data（Sendable），JSON 解析在此处完成，避免跨并发边界传字典。
    private func exchange(_ frames: [[String: Any]]) async -> [[String: Any]]? {
        let payload = frames.compactMap { frame -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        let raw: Data? = await withCheckedContinuation { continuation in
            let runner = MCPProcessRunner(config: config, timeout: timeout)
            runner.run(payload: payload, continuation: continuation)
        }
        guard let raw, let text = String(data: raw, encoding: .utf8) else { return nil }
        let objects = text
            .components(separatedBy: .newlines)
            .compactMap { line -> [String: Any]? in
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return nil }
                return object
            }
        return objects.isEmpty ? nil : objects
    }
}

/// MCP 子进程驱动：写请求、读响应、超时强制收口。复用 run_command 的健壮收口思路。
/// 只回传原始 stdout Data（Sendable），JSON 解析交给调用方，避免跨并发边界传字典。
private final class MCPProcessRunner: @unchecked Sendable {
    private let config: LingShuMCPServerConfig
    private let timeout: TimeInterval
    private let process = Process()
    private let lock = NSLock()
    private var collected = Data()
    private var finished = false
    private var continuation: CheckedContinuation<Data?, Never>?

    init(config: LingShuMCPServerConfig, timeout: TimeInterval) {
        self.config = config
        self.timeout = timeout
    }

    func run(payload: String, continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let fullCommand = "\(config.command) \(config.arguments.joined(separator: " "))"
        process.arguments = ["-c", fullCommand]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let handle = stdout.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.lock()
            if self.collected.count < 262_144 { self.collected.append(chunk) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { self?.conclude(handle: handle) }
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            resumeOnce(nil)
            return
        }

        // 写入请求帧后关闭 stdin，让一发一收型 server 知道输入结束。
        if let data = (payload + "\n").data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let done = self.finished; self.lock.unlock()
            guard !done else { return }
            if self.process.isRunning {
                self.process.terminate()
                kill(self.process.processIdentifier, SIGKILL)
            }
            self.conclude(handle: handle)
        }
    }

    private func conclude(handle: FileHandle) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let data = collected
        lock.unlock()
        handle.readabilityHandler = nil
        resumeOnce(data.isEmpty ? nil : data)
    }

    private func resumeOnce(_ value: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// 连接器注册表：本机 JSON 持久化的 MCP server 配置 + 工具发现缓存。
@MainActor
final class LingShuConnectorRegistry: ObservableObject {
    @Published private(set) var servers: [LingShuMCPServerConfig] = []
    @Published private(set) var discoveredTools: [LingShuMCPToolDescriptor] = []

    private let storeURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingShu/Connectors", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("servers.json")
        load()
    }

    func addServer(name: String, command: String, arguments: [String]) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        servers.append(.init(name: name.isEmpty ? trimmed : name, command: trimmed, arguments: arguments))
        save()
    }

    func removeServer(id: String) {
        servers.removeAll { $0.id == id }
        discoveredTools.removeAll { $0.serverID == id }
        save()
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].enabled = enabled
        save()
    }

    /// 探活并刷新所有启用 server 的工具清单。
    func refreshTools() async {
        var all: [LingShuMCPToolDescriptor] = []
        for server in servers where server.enabled {
            let client = LingShuMCPStdioClient(config: server)
            all.append(contentsOf: await client.listTools())
        }
        discoveredTools = all
    }

    func client(forTool toolName: String) -> LingShuMCPStdioClient? {
        guard let descriptor = discoveredTools.first(where: { $0.name == toolName }),
              let server = servers.first(where: { $0.id == descriptor.serverID && $0.enabled }) else { return nil }
        return LingShuMCPStdioClient(config: server)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([LingShuMCPServerConfig].self, from: data) else { return }
        servers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
