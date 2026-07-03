import Foundation
import Network

/// 诊断日志写到固定文件,绕开中文进程名导致的 unified log 检索不可靠问题。
func lingShuControlLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/lingshu-control.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

/// 本机回环 MCP / JSON-RPC 控制服务。
///
/// 目的：让外部(自动化测试 / Claude / 任意 MCP 客户端)通过 HTTP POST 调用灵枢内部动作,
/// 从而对 M2 会议能力链(听会议 → 转写 → 纪要 → 答疑 → 进会议)做可复现的端到端取证。
///
/// 安全边界：
/// - 仅绑定 127.0.0.1(回环),不监听任何对外网卡。
/// - 可选共享口令：设置环境变量 `LINGSHU_MCP_TOKEN` 后,请求须带 `X-LingShu-Token` 头匹配。
/// - 端口：环境变量 `LINGSHU_MCP_PORT`,默认 8917。
///
/// 协议：HTTP/1.1 一问一答。`POST /`(或 /mcp)携带 JSON-RPC 2.0 报文,支持
/// initialize / tools/list / tools/call / ping。`GET /health` 返回存活探针。
final class LingShuControlServer: @unchecked Sendable {
    static let shared = LingShuControlServer()

    private let queue = DispatchQueue(label: "com.zhaoroy.lingshu.control-server")
    private var listener: NWListener?
    private var dispatcher: (@MainActor @Sendable (Data) async -> Data)?
    private var started = false
    private let token = ProcessInfo.processInfo.environment["LINGSHU_MCP_TOKEN"]
    private(set) var boundPort: UInt16 = 0
    /// 持有活跃连接,否则 handler 在异步回调到达前就被释放。键为对象身份,结束时移除。
    private var activeConnections: [ObjectIdentifier: LingShuControlConnection] = [:]

    private init() {}

    /// 启动控制服务(幂等)。须在 MainActor 上调用,以捕获 @MainActor 的 LingShuState。
    @MainActor
    func start(state: LingShuState) {
        guard !started else { return }
        started = true
        let router = LingShuControlRouter(state: state)
        dispatcher = { @MainActor body in
            await router.handle(requestBody: body)
        }
        let desired = UInt16(ProcessInfo.processInfo.environment["LINGSHU_MCP_PORT"] ?? "") ?? 8917
        NSLog("[LingShuControlServer] start() 已调用, 目标端口 \(desired)")
        queue.async { [weak self] in
            self?.startListener(port: desired)
        }
    }

    private func startListener(port desired: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: desired) else { return }
        let params = NWParameters.tcp
        // 仅回环：限制监听到 loopback 接口(lo0 = 127.0.0.1/::1)。
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("[LingShuControlServer] 启动失败 port=\(desired): \(error)")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let handler = LingShuControlConnection(
                connection: connection,
                queue: self.queue,
                token: self.token,
                dispatcher: self.dispatcher,
                onClose: { [weak self] id in
                    self?.activeConnections[id] = nil
                }
            )
            self.activeConnections[ObjectIdentifier(handler)] = handler
            handler.start()
        }
        listener.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                self?.boundPort = desired
                lingShuControlLog("listener ready @127.0.0.1:\(desired)")
            case .failed(let error):
                lingShuControlLog("listener failed: \(error)")
            default:
                lingShuControlLog("listener state: \(newState)")
            }
        }
        listener.start(queue: queue)
        lingShuControlLog("listener.start() called for port \(desired)")
    }
}

/// 单条 HTTP 连接的读取/分发/回写,自管缓冲与生命周期。
private final class LingShuControlConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String?
    private let dispatcher: (@MainActor @Sendable (Data) async -> Data)?
    private let onClose: (ObjectIdentifier) -> Void
    private var buffer = Data()

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        token: String?,
        dispatcher: (@MainActor @Sendable (Data) async -> Data)?,
        onClose: @escaping (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.dispatcher = dispatcher
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            // 必须等连接 ready 再收数据,否则 receive 不会回调。
            if case .ready = state {
                self?.receive()
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let request = LingShuHTTPRequest(raw: self.buffer) {
                    self.handle(request)
                    return
                }
            }
            if isComplete || error != nil {
                self.finish(status: "400 Bad Request", body: Data("{\"error\":\"malformed request\"}".utf8))
                return
            }
            self.receive()
        }
    }

    private func handle(_ request: LingShuHTTPRequest) {
        if request.method == "GET", request.path.hasPrefix("/health") {
            finish(status: "200 OK", body: Data("{\"status\":\"ok\"}".utf8))
            return
        }
        if let token, !token.isEmpty, request.headerValue("x-lingshu-token") != token {
            finish(status: "401 Unauthorized", body: Data("{\"error\":\"bad token\"}".utf8))
            return
        }
        guard request.method == "POST", let dispatcher else {
            finish(status: "404 Not Found", body: Data("{\"error\":\"use POST with JSON-RPC body\"}".utf8))
            return
        }
        let body = request.body
        if let cachedResponse = LingShuControlSnapshotStore.shared.cachedJSONRPCResponse(for: body) {
            finish(status: "200 OK", body: cachedResponse)
            return
        }
        Task { [weak self] in
            let response = await dispatcher(body)
            guard let self else { return }
            self.queue.async {
                self.finish(status: "200 OK", body: response)
            }
        }
    }

    private func finish(status: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.connection.cancel()
            self.onClose(ObjectIdentifier(self))
        })
    }
}

/// 极简 HTTP 请求解析:够用于一问一答的 JSON-RPC over HTTP。
private struct LingShuHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(raw: Data) {
        guard let headerEndRange = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<headerEndRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        method = parts[0].uppercased()
        path = parts[1]

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsedHeaders[key] = value
        }
        headers = parsedHeaders

        let bodyStart = headerEndRange.upperBound
        let available = raw.subdata(in: bodyStart..<raw.endIndex)
        if let lengthText = parsedHeaders["content-length"], let expected = Int(lengthText) {
            // 报文尚未收全,等待下一次 receive 再解析。
            guard available.count >= expected else { return nil }
            body = available.prefix(expected)
        } else {
            body = available
        }
    }

    func headerValue(_ key: String) -> String? {
        headers[key.lowercased()]
    }
}
