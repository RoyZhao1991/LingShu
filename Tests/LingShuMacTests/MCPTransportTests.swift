import XCTest
@testable import LingShuMac

/// 差距5·MCP 可替换 transport 的守卫:
/// ① HTTP/SSE 纯解析(帧拆分/SSE 抽取/响应压实/JSON 压实)——可单测、不依赖网络;
/// ② 配置向后兼容(旧 servers.json 无 transport/url → 解码为 .stdio);
/// ③ client 经**注入假 transport** 正确解析 tools/list 与 tools/call(验证 transport 接缝)。
final class MCPTransportTests: XCTestCase {

    // MARK: HTTP/SSE 纯解析

    func testParseFramesSplitsNewlineDelimited() {
        let frames = LingShuMCPHTTPTransport.parseFrames("{\"a\":1}\n{\"b\":2}\n\n  \n{\"c\":3}")
        XCTAssertEqual(frames, ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
    }

    func testExtractSSESingleEvent() {
        let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3}\n\n"
        XCTAssertEqual(LingShuMCPHTTPTransport.extractSSEData(body), ["{\"jsonrpc\":\"2.0\",\"id\":3}"])
    }

    func testExtractSSEMultipleEvents() {
        let body = "data: {\"id\":1}\n\ndata: {\"id\":2}\n\n"
        XCTAssertEqual(LingShuMCPHTTPTransport.extractSSEData(body), ["{\"id\":1}", "{\"id\":2}"])
    }

    func testExtractSSEMultiLineDataJoined() {
        // 同一事件内多条 data: 以 \n 拼接(SSE 规范)。
        let body = "data: line1\ndata: line2\n\n"
        XCTAssertEqual(LingShuMCPHTTPTransport.extractSSEData(body), ["line1\nline2"])
    }

    func testExtractSSEIgnoresCommentsAndFields() {
        let body = ": 这是注释\nid: 42\nevent: message\ndata: {\"ok\":true}\n\n"
        XCTAssertEqual(LingShuMCPHTTPTransport.extractSSEData(body), ["{\"ok\":true}"])
    }

    func testCompactJSONFlattensPrettyPrinted() {
        let pretty = "{\n  \"id\" : 3\n}"
        let compact = LingShuMCPHTTPTransport.compactJSON(pretty)
        XCTAssertNotNil(compact)
        XCTAssertFalse(compact!.contains("\n"))
        XCTAssertEqual(compact, "{\"id\":3}")
    }

    func testCompactJSONRejectsInvalid() {
        XCTAssertNil(LingShuMCPHTTPTransport.compactJSON("不是 json"))
        XCTAssertNil(LingShuMCPHTTPTransport.compactJSON("   "))
    }

    func testResponseObjectsApplicationJSONCompactsToSingleLine() {
        let body = "{\n  \"jsonrpc\": \"2.0\",\n  \"id\": 3\n}".data(using: .utf8)!
        let objs = LingShuMCPHTTPTransport.responseObjects(body: body, contentType: "application/json; charset=utf-8")
        XCTAssertEqual(objs.count, 1)
        XCTAssertFalse(objs[0].contains("\n"), "application/json 多行响应必须压实成单行供 client 按行解析")
        let parsed = try? JSONSerialization.jsonObject(with: Data(objs[0].utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["id"] as? Int, 3)
    }

    func testResponseObjectsSSE() {
        let body = "data: {\"id\":2,\"result\":{}}\n\n".data(using: .utf8)!
        let objs = LingShuMCPHTTPTransport.responseObjects(body: body, contentType: "text/event-stream")
        XCTAssertEqual(objs, ["{\"id\":2,\"result\":{}}"])
    }

    func testResponseObjectsArrayBatch() {
        let body = "[{\"id\":1},{\"id\":2}]".data(using: .utf8)!
        let objs = LingShuMCPHTTPTransport.responseObjects(body: body, contentType: "application/json")
        XCTAssertEqual(objs.count, 2)
    }

    // MARK: 配置向后兼容

    func testConfigDecodesLegacyWithoutTransportAsStdio() throws {
        // 旧 servers.json:无 transport/url 字段。
        let legacy = "[{\"id\":\"x\",\"name\":\"fs\",\"command\":\"npx\",\"arguments\":[\"-y\",\"s\"],\"enabled\":true}]"
        let decoded = try JSONDecoder().decode([LingShuMCPServerConfig].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].transport, .stdio)
        XCTAssertEqual(decoded[0].command, "npx")
        XCTAssertEqual(decoded[0].url, "")
    }

    func testConfigDecodesHTTP() throws {
        let json = "[{\"id\":\"y\",\"name\":\"remote\",\"transport\":\"http\",\"url\":\"https://mcp.example.com\",\"enabled\":true}]"
        let decoded = try JSONDecoder().decode([LingShuMCPServerConfig].self, from: Data(json.utf8))
        XCTAssertEqual(decoded[0].transport, .http)
        XCTAssertEqual(decoded[0].url, "https://mcp.example.com")
    }

    func testConfigRoundTrips() throws {
        let cfg = LingShuMCPServerConfig(name: "remote", transport: .http, url: "https://x.dev/mcp")
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(LingShuMCPServerConfig.self, from: data)
        XCTAssertEqual(cfg, back)
    }

    // MARK: client 经注入假 transport 解析

    private struct FakeTransport: LingShuMCPTransport {
        let response: String
        func exchange(payload: String) async -> Data? { response.data(using: .utf8) }
    }

    func testClientListToolsParsesViaTransport() async {
        let resp = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"get_weather\",\"description\":\"天气\"}]}}"
        let cfg = LingShuMCPServerConfig(name: "s", transport: .http, url: "https://x")
        let client = LingShuMCPClient(config: cfg, transport: FakeTransport(response: resp))
        let tools = await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["get_weather"])
        XCTAssertEqual(tools.first?.description, "天气")
    }

    func testClientCallToolParsesViaTransport() async {
        let resp = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"晴 26°C\"}]}}"
        let cfg = LingShuMCPServerConfig(name: "s", transport: .http, url: "https://x")
        let client = LingShuMCPClient(config: cfg, transport: FakeTransport(response: resp))
        let result = await client.callTool(name: "get_weather", arguments: ["city": "上海"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "晴 26°C")
    }

    func testClientCallToolSurfacesError() async {
        let resp = "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32000,\"message\":\"工具不存在\"}}"
        let cfg = LingShuMCPServerConfig(name: "s")
        let client = LingShuMCPClient(config: cfg, transport: FakeTransport(response: resp))
        let result = await client.callTool(name: "nope", arguments: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("工具不存在"))
    }

    func testClientNoResponseFailsGracefully() async {
        struct DeadTransport: LingShuMCPTransport { func exchange(payload: String) async -> Data? { nil } }
        let client = LingShuMCPClient(config: .init(name: "s"), transport: DeadTransport())
        let result = await client.callTool(name: "x", arguments: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("无响应") || result.output.contains("连接失败"))
    }
}
