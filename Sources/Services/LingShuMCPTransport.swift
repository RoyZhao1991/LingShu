import Foundation
import Network

/// 差距5·**MCP 传输层可替换模块 + 持久连接**:把 JSON-RPC 请求送到 server 并取回原始响应字节。
///
/// 设计取向(协议 + 多实现 + 由 config/开关选择):**transport 负责握手(initialize 一次)+ 搬字节;client 只发业务请求**
/// (tools/list、tools/call),不再每次自带 initialize。用序列化文本进 / 原始 Data 出(newline-delimited JSON,client 按 id 配对),
/// 规避 `[String:Any]` 的 Sendable 问题。
/// - `LingShuMCPStdioTransport`(actor):本机 MCP server 子进程;**持久=进程常驻、握手一次**,出错自愈(销毁→下次重连)。
/// - `LingShuMCPHTTPTransport`(actor):Streamable HTTP;**持久=`Mcp-Session-Id` 会话复用、initialize 一次**,出错清会话重连。
/// 开关 `lingshu.mcpPersistent`(默认开)可切回"每次新连"(stateless)。**自愈有界**:任何超时/失败即拆连,绝不留 wedge。
protocol LingShuMCPTransport: Sendable {
    /// 发若干**业务**请求帧(每行一个 JSON-RPC 文本,**不含 initialize**——transport 负责握手),
    /// 返回这些请求的响应(newline-delimited JSON Data,client 按 id 配对)。nil=连接/传输失败。
    func exchange(payload: String) async -> Data?
    /// 主动断开(释放常驻连接)。默认空实现。
    func shutdown() async
}

extension LingShuMCPTransport {
    func shutdown() async {}
    /// 是否持久复用连接(默认开;`lingshu.mcpPersistent=false` 切回每次新连)。
    static var persistentByDefault: Bool {
        (LingShuRuntimeEnvironment.preferences.object(forKey: "lingshu.mcpPersistent") as? Bool) ?? true
    }
    /// 标准 initialize 帧(transport 握手用)。
    static func initializeFrames() -> [[String: Any]] {
        [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:] as [String: Any],
                        "clientInfo": ["name": "LingShu", "version": "1.0"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"]
        ]
    }
    static func serialize(_ frames: [[String: Any]]) -> String {
        frames.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) } }
            .joined(separator: "\n")
    }
}

/// 由 config 选 transport(单一构造点)。persistent 默认开。
enum LingShuMCPTransportFactory {
    static func make(config: LingShuMCPServerConfig, timeout: TimeInterval = 30,
                     persistent: Bool? = nil) -> any LingShuMCPTransport {
        let p = persistent ?? LingShuMCPHTTPTransport.persistentByDefault
        switch config.transport {
        case .http: return LingShuMCPHTTPTransport(endpoint: config.url, timeout: timeout, persistent: p)
        case .stdio: return LingShuMCPStdioTransport(config: config, timeout: timeout, persistent: p)
        }
    }
}

// MARK: - stdio(子进程;持久=进程常驻握手一次,自愈)

actor LingShuMCPStdioTransport: LingShuMCPTransport {
    private let config: LingShuMCPServerConfig
    private let timeout: TimeInterval
    private let persistent: Bool
    private var session: LingShuStdioSession?

    init(config: LingShuMCPServerConfig, timeout: TimeInterval = 30, persistent: Bool = true) {
        self.config = config
        self.timeout = timeout
        self.persistent = persistent
    }

    func exchange(payload: String) async -> Data? {
        let businessFrames = payload.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let businessIDs = businessFrames.compactMap { LingShuMCPFraming.frameID($0) }

        guard let live = await ensureConnected() else { return nil }
        // 发业务帧。
        for frame in businessFrames { live.write(frame) }
        // 等每个业务 id 的响应(有界超时);任一缺失即判失败→拆连自愈。
        var lines: [String] = []
        for id in businessIDs {
            guard let line = await live.awaitLine(id: id, timeout: timeout) else {
                await tearDown()
                return lines.isEmpty ? nil : lines.joined(separator: "\n").data(using: .utf8)
            }
            lines.append(line)
        }
        if !persistent { await tearDown() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n").data(using: .utf8)
    }

    func shutdown() async { await tearDown() }

    /// 确保已连接 + 握手一次(持久则复用)。失败返回 nil。
    private func ensureConnected() async -> LingShuStdioSession? {
        if let s = session, s.isAlive { return s }
        session = nil
        let s = LingShuStdioSession()
        guard s.start(command: config.command, arguments: config.arguments) else { return nil }
        // 握手:发 initialize(id 1)+ initialized 通知,等 id 1 响应。
        let initFrames = Self.initializeFrames()
        for f in initFrames { if let line = LingShuMCPFraming.compact(f) { s.write(line) } }
        guard await s.awaitLine(id: 1, timeout: timeout) != nil else { s.stop(); return nil }
        session = s
        return s
    }

    private func tearDown() async {
        session?.stop()
        session = nil
    }
}

/// 常驻 stdio 会话:长生命进程 + 行缓冲读取器 + 按 id 取响应(轮询有界)。lock 保护跨并发。
final class LingShuStdioSession: @unchecked Sendable {
    private struct ParsedFrame: Sendable {
        let id: Int
        let compactJSON: String
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var parsed: [ParsedFrame] = []   // 已解析、待按 id 消费的可发送 JSON 帧(有上限)
    private var started = false

    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return started && process.isRunning }

    func start(command: String, arguments: [String]) -> Bool {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "\(command) \(arguments.joined(separator: " "))"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let handle = stdout.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let self else { return }
            self.ingest(chunk)
        }
        do { try process.run() } catch { handle.readabilityHandler = nil; return false }
        lock.lock(); started = true; lock.unlock()
        return true
    }

    /// 累积字节→切完整行→解析 JSON 对象→入队(有上限,防无界增长)。
    private func ingest(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = object["id"] as? Int,
                  let compactJSON = LingShuMCPFraming.compact(object) else { continue }
            parsed.append(.init(id: id, compactJSON: compactJSON))
            if parsed.count > 256 { parsed.removeFirst(parsed.count - 256) }
        }
    }

    func write(_ frame: String) {
        guard let data = (frame + "\n").data(using: .utf8) else { return }
        stdin.fileHandleForWriting.write(data)
    }

    /// 同步取一条 id 匹配的响应文本(加锁临界区;无则 nil)。async 轮询调它,锁不跨 await。
    private func takeLine(id: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let index = parsed.firstIndex(where: { $0.id == id }) else { return nil }
        return parsed.remove(at: index).compactJSON
    }

    /// 轮询取一条 id 匹配的响应(有界超时,自带让步)。找到即从队列移除返回。
    func awaitLine(id: Int, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = takeLine(id: id) { return line }
            if !isAlive { return nil }
            try? await Task.sleep(nanoseconds: 15_000_000)   // 15ms 让步
        }
        return nil
    }

    func stop() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        lock.lock(); started = false; lock.unlock()
    }
}

// MARK: - HTTP / SSE(Streamable HTTP;持久=session-id 复用,握手一次,自愈)

actor LingShuMCPHTTPTransport: LingShuMCPTransport {
    private let endpoint: String
    private let timeout: TimeInterval
    private let persistent: Bool
    private let session = URLSession(configuration: .ephemeral)
    private var sessionID: String?
    private var initialized = false

    init(endpoint: String, timeout: TimeInterval = 30, persistent: Bool = true) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.persistent = persistent
    }

    func exchange(payload: String) async -> Data? {
        guard let url = URL(string: endpoint), url.scheme == "http" || url.scheme == "https" else { return nil }
        guard await ensureInitialized(url: url) else { await tearDown(); return nil }

        var outLines: [String] = []
        for frame in payload.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            guard let (data, ct) = await post(frame: frame, url: url) else { await tearDown(); break }
            outLines.append(contentsOf: LingShuMCPHTTPTransport.responseObjects(body: data, contentType: ct))
        }
        if !persistent { await tearDown() }
        return outLines.isEmpty ? nil : outLines.joined(separator: "\n").data(using: .utf8)
    }

    func shutdown() async { await tearDown() }

    /// initialize 一次(持久复用)。捕获 `Mcp-Session-Id`、发 initialized 通知。
    private func ensureInitialized(url: URL) async -> Bool {
        if initialized { return true }
        let frames = Self.initializeFrames()
        guard let initFrame = LingShuMCPFraming.compact(frames[0]),
              let (_, _) = await post(frame: initFrame, url: url) else { return false }
        if let notif = LingShuMCPFraming.compact(frames[1]) { _ = await post(frame: notif, url: url) }
        initialized = true
        return true
    }

    /// 单帧 POST,返回(响应体, content-type);捕获/回传 session-id。
    private func post(frame: String, url: URL) async -> (Data, String)? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sid = sessionID { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = frame.data(using: .utf8)
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty { sessionID = sid }
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return (data, ct)
    }

    private func tearDown() {
        sessionID = nil
        initialized = false
    }

    // MARK: 纯逻辑(可单测,不依赖网络)

    static func parseFrames(_ payload: String) -> [String] {
        payload.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 从 HTTP 响应体抽各 JSON-RPC 消息,压实成单行。`text/event-stream`→SSE;否则单 JSON(对象/数组)。
    static func responseObjects(body: Data, contentType: String) -> [String] {
        let text = String(decoding: body, as: UTF8.self)
        if contentType.contains("text/event-stream") {
            return extractSSEData(text).compactMap { compactJSON($0) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let arr = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [[String: Any]] {
            return arr.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) } }
        }
        return compactJSON(trimmed).map { [$0] } ?? []
    }

    /// SSE 解析:空行分隔事件,事件内多 `data:` 以 `\n` 拼接;忽略 `event:`/`id:`/`retry:`/注释。
    static func extractSSEData(_ body: String) -> [String] {
        var results: [String] = []
        var current: [String] = []
        func flush() { if !current.isEmpty { results.append(current.joined(separator: "\n")); current.removeAll() } }
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if line.hasPrefix("data:") {
                var v = String(line.dropFirst(5)); if v.hasPrefix(" ") { v.removeFirst() }
                current.append(v)
            }
        }
        flush()
        return results
    }

    static func compactJSON(_ s: String) -> String? { LingShuMCPFraming.compactString(s) }
}

// MARK: - 帧工具(纯逻辑共用)

enum LingShuMCPFraming {
    static func frameID(_ frameJSON: String) -> Int? {
        guard let data = frameJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["id"] as? Int
    }
    static func compact(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func compactString(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: compact, encoding: .utf8) else { return nil }
        return str
    }
}
