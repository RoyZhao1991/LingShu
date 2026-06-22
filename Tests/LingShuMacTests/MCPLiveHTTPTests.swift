import XCTest
import Network
@testable import LingShuMac

/// 差距5·**HTTP transport live E2E + 持久连接验证**(打真 localhost socket,非纯逻辑 mock)。
/// 用 NWListener 起一个最小 MCP HTTP server(initialize→带 session-id;tools/list→JSON;tools/call→**SSE**),
/// 断言:① LingShuMCPClient(http transport)真能 listTools/callTool 跑通(含 SSE 解析);
/// ② **持久**:initialize 跨多次工具调用**只握手一次**;③ **非持久**:每次调用都重新 initialize(对照)。
final class MCPLiveHTTPTests: XCTestCase {

    func testHTTPClientLiveRoundTripAndPersistence() async throws {
        let server = MockMCPHTTPServer()
        guard let port = await server.start() else {
            throw XCTSkip("无法启动本地 mock server(端口/沙箱限制),跳过 live E2E")
        }
        defer { server.stop() }
        let url = "http://127.0.0.1:\(port)/mcp"
        let cfg = LingShuMCPServerConfig(name: "mock", transport: .http, url: url)

        // —— 持久 transport:同一 client 连发 listTools + callTool —— //
        let persistent = LingShuMCPHTTPTransport(endpoint: url, timeout: 5, persistent: true)
        let client = LingShuMCPClient(config: cfg, transport: persistent)

        let tools = await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"], "live tools/list 应返回 echo")

        let result = await client.callTool(name: "echo", arguments: ["msg": "hi"])
        XCTAssertTrue(result.success, "live tools/call 应成功:\(result.output)")
        XCTAssertEqual(result.output, "echo:hi", "应正确解析 SSE 响应体")

        XCTAssertEqual(server.initCount, 1, "持久连接:initialize 跨两次工具调用只握手一次(实测 \(server.initCount))")

        // —— 非持久 transport:每次 exchange 都重新 initialize —— //
        let before = server.initCount
        let stateless = LingShuMCPHTTPTransport(endpoint: url, timeout: 5, persistent: false)
        let c2 = LingShuMCPClient(config: cfg, transport: stateless)
        _ = await c2.listTools()
        _ = await c2.listTools()
        XCTAssertEqual(server.initCount - before, 2, "非持久:两次调用应各自重新 initialize(实测 +\(server.initCount - before))")
    }
}

/// 一次性触发守卫(锁保护,供并发回调安全 resume 一次)。
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// 最小 MCP HTTP mock server(测试用)。HTTP/1.1 一问一答;tools/call 走 SSE 以验证 SSE 解析。
final class MockMCPHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mock.mcp.http")
    private let lock = NSLock()
    private var _initCount = 0
    var initCount: Int { lock.lock(); defer { lock.unlock() }; return _initCount }

    func start() async -> UInt16? {
        guard let l = try? NWListener(using: .tcp) else { return nil }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire(), let p = l.port?.rawValue { cont.resume(returning: p) }
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let body = Self.completeBody(buf) {
                let (respBody, sessionID, contentType, status) = self.respond(to: body)
                conn.send(content: Self.httpResponse(body: respBody, contentType: contentType, sessionID: sessionID, status: status),
                          completion: .contentProcessed { _ in conn.cancel() })
            } else if isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// 收到完整 HTTP 请求(headers + Content-Length 字节的 body)→ 返回 body 字符串;否则 nil(继续收)。
    private static func completeBody(_ buf: Data) -> String? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
        var contentLength = 0
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyData = buf[headerEnd.upperBound...]
        guard bodyData.count >= contentLength else { return nil }
        return String(decoding: bodyData.prefix(contentLength), as: UTF8.self)
    }

    /// 按 JSON-RPC method 应答。tools/call 走 SSE。
    private func respond(to body: String) -> (body: String, sessionID: String?, contentType: String, status: String) {
        let obj = (body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let method = (obj["method"] as? String) ?? ""
        switch method {
        case "initialize":
            lock.lock(); _initCount += 1; lock.unlock()
            let r = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"mock\",\"version\":\"1\"}}}"
            return (r, "mock-session-abc", "application/json", "200 OK")
        case "notifications/initialized":
            return ("", nil, "application/json", "202 Accepted")
        case "tools/list":
            let r = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"回声\"}]}}"
            return (r, nil, "application/json", "200 OK")
        case "tools/call":
            // SSE 响应:验证 transport 的 SSE 解析路径。
            let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"echo:hi\"}]}}\n\n"
            return (sse, nil, "text/event-stream", "200 OK")
        default:
            return ("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"unknown\"}}", nil, "application/json", "200 OK")
        }
    }

    private static func httpResponse(body: String, contentType: String, sessionID: String?, status: String) -> Data {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n"
        if let sid = sessionID { head += "Mcp-Session-Id: \(sid)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + bodyData
    }
}
