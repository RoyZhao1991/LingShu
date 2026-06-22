import Foundation

/// MCP 连接器配置:一个外部 MCP server。支持两种 transport(差距5):
/// - `.stdio`:本机子进程(command + arguments)。
/// - `.http`:Streamable HTTP 远程/托管 server(url)。
/// 配置存 ~/Library/Application Support/LingShu/Connectors/servers.json。
/// **向后兼容**:旧配置无 transport/url 字段 → 解码为 `.stdio`(自定义 `init(from:)` 容忍缺字段)。
struct LingShuMCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    enum Transport: String, Codable, Sendable { case stdio, http }

    var id: String
    var name: String
    var transport: Transport
    var command: String       // stdio
    var arguments: [String]   // stdio
    var url: String           // http
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, transport: Transport = .stdio,
         command: String = "", arguments: [String] = [], url: String = "", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .stdio
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// 一个 MCP server 暴露的工具描述。
struct LingShuMCPToolDescriptor: Equatable, Sendable {
    var serverID: String
    var serverName: String
    var name: String
    var description: String
}

/// MCP 客户端:只管 JSON-RPC 2.0 语义(initialize / tools/list / tools/call),搬字节交给可替换 `transport`(stdio / HTTP)。
/// 每次逻辑调用走一次 transport.exchange(一发一收,内含 initialize 握手)——足够把外部工具接进 agent 循环。
/// (持久双工连接=后续在 transport 层升级,对外契约不变。)
final class LingShuMCPClient: @unchecked Sendable {
    private let config: LingShuMCPServerConfig
    private let transport: any LingShuMCPTransport

    init(config: LingShuMCPServerConfig, transport: any LingShuMCPTransport) {
        self.config = config
        self.transport = transport
    }

    convenience init(config: LingShuMCPServerConfig, timeout: TimeInterval = 30) {
        self.init(config: config, transport: LingShuMCPTransportFactory.make(config: config, timeout: timeout))
    }

    /// 列出 server 暴露的工具。**只发业务帧**——initialize 握手由 transport 负责(持久则一次,见 LingShuMCPTransport)。
    func listTools() async -> [LingShuMCPToolDescriptor] {
        let frames: [[String: Any]] = [
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

    /// 调用一个工具,返回文本结果。
    func callTool(name: String, arguments: [String: Any]) async -> LingShuToolResult {
        let frames: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        ]
        guard let responses = await exchange(frames) else {
            return .init(tool: "mcp:\(name)", success: false, output: "MCP server \(config.name) 无响应或连接失败。")
        }
        for response in responses where (response["id"] as? Int) == 3 {
            if let error = response["error"] as? [String: Any] {
                return .init(tool: "mcp:\(name)", success: false, output: "MCP 错误:\(error["message"] as? String ?? "未知")")
            }
            if let result = response["result"] as? [String: Any] {
                let text = Self.extractText(from: result)
                let isError = (result["isError"] as? Bool) ?? false
                return .init(tool: "mcp:\(name)", success: !isError, output: text.isEmpty ? "(无文本结果)" : text)
            }
        }
        return .init(tool: "mcp:\(name)", success: false, output: "MCP server \(config.name) 未返回 tools/call 结果。")
    }

    // MARK: - 内部

    static func extractText(from result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block -> String? in
            if (block["type"] as? String) == "text" { return block["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    /// 序列化请求帧(每行一个 JSON)→ 交 transport 搬字节 → 按行解析回 JSON 对象。
    /// transport 是可替换模块:stdio 走子进程、HTTP 走 Streamable HTTP/SSE,本方法对两者一视同仁。
    private func exchange(_ frames: [[String: Any]]) async -> [[String: Any]]? {
        let payload = frames.compactMap { frame -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        guard let raw = await transport.exchange(payload: payload),
              let text = String(data: raw, encoding: .utf8) else { return nil }
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

/// 连接器注册表:本机 JSON 持久化的 MCP server 配置 + 工具发现缓存。
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

    /// 添加本机 stdio server。
    func addServer(name: String, command: String, arguments: [String]) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        servers.append(.init(name: name.isEmpty ? trimmed : name, transport: .stdio, command: trimmed, arguments: arguments))
        save()
    }

    /// 添加远程/托管 HTTP(Streamable HTTP)server——差距5:吃跨厂商现成生态。
    func addHTTPServer(name: String, url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
        servers.append(.init(name: name.isEmpty ? trimmed : name, transport: .http, url: trimmed))
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
            let client = LingShuMCPClient(config: server)
            all.append(contentsOf: await client.listTools())
        }
        discoveredTools = all
    }

    func client(forTool toolName: String) -> LingShuMCPClient? {
        guard let descriptor = discoveredTools.first(where: { $0.name == toolName }),
              let server = servers.first(where: { $0.id == descriptor.serverID && $0.enabled }) else { return nil }
        return LingShuMCPClient(config: server)
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
