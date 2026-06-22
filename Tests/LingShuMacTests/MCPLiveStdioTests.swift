import XCTest
@testable import LingShuMac

/// 差距5·**stdio 持久 transport live E2E**(真起子进程跑 mock MCP server):
/// 断言 ① 真能 listTools/callTool 跑通;② **持久=进程跨多次工具调用只起一次**(对照非持久每次新起)。
final class MCPLiveStdioTests: XCTestCase {

    /// 定位仓库内的 mock 脚本(从本测试文件路径推项目根)。
    private func mockScriptPath() -> String? {
        let here = URL(fileURLWithPath: #filePath)            // Tests/LingShuMacTests/MCPLiveStdioTests.swift
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/mock-mcp-stdio.py").path
        return FileManager.default.fileExists(atPath: script) ? script : nil
    }

    private func spawnCount(_ file: String) -> Int {
        (try? String(contentsOfFile: file, encoding: .utf8))?
            .split(separator: "\n").filter { !$0.isEmpty }.count ?? 0
    }

    func testStdioPersistentRoundTripAndProcessReuse() async throws {
        guard let script = mockScriptPath() else { throw XCTSkip("缺 Scripts/mock-mcp-stdio.py") }
        // python3 可用?
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
                || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
                || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3") else {
            throw XCTSkip("无 python3,跳过 stdio live E2E")
        }
        let spawnFile = NSTemporaryDirectory() + "mock-mcp-spawn-\(UUID().uuidString).txt"
        setenv("MOCK_MCP_SPAWN_FILE", spawnFile, 1)
        defer { unsetenv("MOCK_MCP_SPAWN_FILE"); try? FileManager.default.removeItem(atPath: spawnFile) }

        let cfg = LingShuMCPServerConfig(name: "stdio-mock", transport: .stdio, command: "python3", arguments: [script])

        // —— 持久:同一 client 连发 listTools + callTool,进程应只起一次 —— //
        let persistent = LingShuMCPStdioTransport(config: cfg, timeout: 8, persistent: true)
        let client = LingShuMCPClient(config: cfg, transport: persistent)

        let tools = await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo_stdio"], "live stdio tools/list 应返回 echo_stdio")

        let result = await client.callTool(name: "echo_stdio", arguments: ["x": 1])
        XCTAssertTrue(result.success, "live stdio tools/call 应成功:\(result.output)")
        XCTAssertEqual(result.output, "stdio-ok")

        await persistent.shutdown()
        XCTAssertEqual(spawnCount(spawnFile), 1, "持久:进程跨两次工具调用只起一次(实测起 \(spawnCount(spawnFile)) 次)")

        // —— 非持久:每次 exchange 新起进程 —— //
        let before = spawnCount(spawnFile)
        let stateless = LingShuMCPStdioTransport(config: cfg, timeout: 8, persistent: false)
        let c2 = LingShuMCPClient(config: cfg, transport: stateless)
        _ = await c2.listTools()
        _ = await c2.listTools()
        XCTAssertEqual(spawnCount(spawnFile) - before, 2, "非持久:两次调用各起一次(实测 +\(spawnCount(spawnFile) - before))")
    }
}
