import XCTest
@testable import LingShuMac

/// 超越点·灵枢当 MCP server:具身工具暴露清单的守卫(纯逻辑,不依赖运行中的 server)。
/// ① 过滤只留具身工具;② tools/list 描述符良构(name/description/inputSchema,schema 由 parametersJSON 解析);
/// ③ tools/call 按名解析到真 handler;④ 开关可关(关则不暴露)。
final class EmbodimentManifestTests: XCTestCase {

    private func tool(_ name: String, _ desc: String = "d", schema: String = "{\"type\":\"object\",\"properties\":{}}", out: String = "ok") -> LingShuAgentTool {
        LingShuAgentTool(name: name, description: desc, parametersJSON: schema) { _ in out }
    }

    /// 混合一批工具:具身的(screen_capture/browser_eval/speak/peripherals)+ 非具身的(read_file/spawn_task/ask_user)。
    private func mixedTools() -> [LingShuAgentTool] {
        [
            tool("screen_capture", "截屏看屏"),
            tool("computer_get_state", "读取应用状态"),
            tool("browser_eval", "网页执行JS", schema: "{\"type\":\"object\",\"properties\":{\"js\":{\"type\":\"string\"}},\"required\":[\"js\"]}"),
            tool("speak", "念出"),
            tool("peripherals", "外设列表"),
            tool("read_file", "读文件"),
            tool("spawn_task", "派生子任务"),
            tool("ask_user", "问用户"),
        ]
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "lingshu.exposeEmbodiment")   // 回到默认(开)
    }

    func testFilterKeepsOnlyEmbodied() {
        let body = LingShuEmbodimentManifest.filter(mixedTools())
        let names = Set(body.map(\.name))
        XCTAssertEqual(names, ["screen_capture", "computer_get_state", "browser_eval", "speak", "peripherals"])
        XCTAssertFalse(names.contains("read_file"))
        XCTAssertFalse(names.contains("spawn_task"))
        XCTAssertFalse(names.contains("ask_user"))
    }

    func testDescriptorsWellFormed() {
        let descs = LingShuEmbodimentManifest.descriptors(from: mixedTools())
        XCTAssertEqual(descs.count, 5)
        guard let evalDesc = descs.first(where: { ($0["name"] as? String) == "browser_eval" }) else {
            return XCTFail("应含 browser_eval 描述符")
        }
        XCTAssertTrue((evalDesc["description"] as? String)?.hasPrefix("[灵枢具身]") ?? false)
        // inputSchema 由 parametersJSON 解析成对象,保留 required。
        let schema = evalDesc["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertEqual(schema?["required"] as? [String], ["js"])
    }

    func testToolLookupResolvesHandler() async {
        let body = mixedTools()
        let resolved = LingShuEmbodimentManifest.tool(named: "speak", in: body)
        XCTAssertNotNil(resolved)
        let out = await resolved?.handler("{}")
        XCTAssertEqual(out, "ok")
        // 非具身工具不暴露(即便在工具集里)。
        XCTAssertNil(LingShuEmbodimentManifest.tool(named: "read_file", in: body))
    }

    func testDisabledExposesNothing() {
        UserDefaults.standard.set(false, forKey: "lingshu.exposeEmbodiment")
        defer { UserDefaults.standard.removeObject(forKey: "lingshu.exposeEmbodiment") }
        XCTAssertTrue(LingShuEmbodimentManifest.filter(mixedTools()).isEmpty)
        XCTAssertTrue(LingShuEmbodimentManifest.descriptors(from: mixedTools()).isEmpty)
        XCTAssertNil(LingShuEmbodimentManifest.tool(named: "speak", in: mixedTools()))
    }
}
