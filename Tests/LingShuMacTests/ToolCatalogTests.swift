import XCTest
@testable import LingShuMac

/// 差距7-B·工具目录延迟加载守卫:
/// ① 相关性排序/分词(纯逻辑);② 暴露集 holder 读写;③ build 核心暴露/长尾延迟/search_tools 激活;
/// ④ **端到端动态暴露**:真 session 跑——激活前模型看不到长尾工具,search_tools 后看得到且可执行,循环恒良构。
final class ToolCatalogTests: XCTestCase {

    private func tool(_ name: String, _ desc: String, out: String = "") -> LingShuAgentTool {
        LingShuAgentTool(name: name, description: desc) { _ in out.isEmpty ? "\(name)-ok" : out }
    }

    // MARK: 分词 / 排序

    func testTokenizeEnglishAndCJK() {
        XCTAssertEqual(LingShuToolRelevance.tokenize("browser automation"), ["browser", "automation"])
        XCTAssertEqual(LingShuToolRelevance.tokenize("浏览器"), ["浏", "览", "器"])
    }

    func testRankNameBeatsDescription() {
        let tools = [
            tool("browser_open", "打开标签"),
            tool("read_file", "读取浏览器导出的文件"),   // 描述里含"浏览器"但名字无关
        ]
        let ranked = LingShuToolRelevance.rank(query: "browser", tools: tools, limit: 5)
        XCTAssertEqual(ranked.first?.name, "browser_open", "名字命中应排在描述命中之前")
    }

    func testRankNoMatchEmpty() {
        let ranked = LingShuToolRelevance.rank(query: "完全无关xyz", tools: [tool("browser_open", "网页")], limit: 5)
        XCTAssertTrue(ranked.isEmpty)
    }

    // MARK: 暴露集

    func testExposedSetReadWrite() {
        let s = LingShuExposedToolSet(initial: ["a", "b"])
        XCTAssertTrue(s.contains("a"))
        XCTAssertFalse(s.contains("c"))
        s.add(["c", "d"])
        XCTAssertTrue(s.contains("c"))
        XCTAssertEqual(s.snapshot(), ["a", "b", "c", "d"])
    }

    // MARK: build

    func testBuildExposesCoreHidesDeferred() {
        let all = [tool("read_file", "读"), tool("write_file", "写"), tool("browser_open", "浏览器"), tool("set_digital_human", "数字人")]
        let built = LingShuToolCatalog.build(allTools: all)
        // 全量 handler + search_tools 都在工具列表里(可执行)。
        XCTAssertTrue(built.tools.contains { $0.name == "search_tools" })
        XCTAssertTrue(built.tools.contains { $0.name == "browser_open" })
        // 初始暴露集=核心∪search_tools,长尾不暴露。
        XCTAssertTrue(built.exposed.contains("read_file"))
        XCTAssertTrue(built.exposed.contains("search_tools"))
        XCTAssertFalse(built.exposed.contains("browser_open"))
        XCTAssertFalse(built.exposed.contains("set_digital_human"))
    }

    func testRecallLocalAlwaysExposedEvenWhenDeferred() {
        // 本机知识检索=基础能力,延迟加载下也必须恒暴露(不被藏到 search_tools 后)。
        let all = [tool("read_file", "读"), tool("recall_local", "本机知识检索"), tool("browser_open", "浏览器")]
        let built = LingShuToolCatalog.build(allTools: all)
        XCTAssertTrue(built.exposed.contains("recall_local"), "recall_local 是基础能力,延迟加载下也应恒暴露")
        XCTAssertFalse(built.exposed.contains("browser_open"), "长尾工具仍延迟")
        XCTAssertTrue(LingShuToolCatalog.coreToolNames.contains("recall_local"))
    }

    func testSearchToolActivatesMatched() async {
        let all = [tool("read_file", "读"), tool("browser_open", "打开内置浏览器做网页自动化")]
        let built = LingShuToolCatalog.build(allTools: all)
        let search = built.tools.first { $0.name == "search_tools" }!
        let reply = await search.handler("{\"query\":\"浏览器\"}")
        XCTAssertTrue(reply.contains("browser_open"), "应回报激活的工具用法:\(reply)")
        XCTAssertTrue(built.exposed.contains("browser_open"), "search_tools 后长尾工具应被激活")
    }

    func testSearchToolNoMatchGivesGuidance() async {
        let built = LingShuToolCatalog.build(allTools: [tool("read_file", "读"), tool("browser_open", "网页")])
        let search = built.tools.first { $0.name == "search_tools" }!
        let reply = await search.handler("{\"query\":\"zzz无关\"}")
        XCTAssertTrue(reply.contains("没找到"))
        XCTAssertFalse(built.exposed.contains("browser_open"))
    }

    // MARK: 端到端动态暴露(真 session)

    /// 记录每次 respond 收到的工具名,验证延迟加载真把 schema 收窄/扩张。
    private final class RecordingModel: LingShuAgentModel, @unchecked Sendable {
        private let script: [LingShuAgentModelResponse]
        private var i = 0
        private(set) var seenToolNames: [[String]] = []
        init(_ s: [LingShuAgentModelResponse]) { script = s }
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            seenToolNames.append(tools.map(\.name).sorted())
            defer { i += 1 }
            return i < script.count ? script[i] : .text("(脚本耗尽)")
        }
    }

    func testDeferredExposureEndToEnd() async {
        let all = [
            tool("read_file", "读取文件"),
            tool("browser_open", "打开内置浏览器标签页做网页演示与自动化", out: "BROWSER_OPENED"),
        ]
        let built = LingShuToolCatalog.build(allTools: all)
        let model = RecordingModel([
            .toolCalls([.init(id: "s1", name: "search_tools", argumentsJSON: "{\"query\":\"浏览器\"}")]),
            .toolCalls([.init(id: "b1", name: "browser_open", argumentsJSON: "{}")]),
            .text("已打开浏览器"),
        ])
        let session = LingShuAgentSession(id: "deferred", tools: built.tools, model: model,
                                          maxTurns: 10, exposedToolNames: built.exposed)
        let result = await session.send("打开浏览器演示")

        XCTAssertEqual(result, .completed(text: "已打开浏览器"))
        // 第一次 respond:模型只看到核心 + search_tools,**看不到 browser_open**。
        XCTAssertFalse(model.seenToolNames[0].contains("browser_open"), "激活前模型不应看到长尾工具:\(model.seenToolNames[0])")
        XCTAssertTrue(model.seenToolNames[0].contains("search_tools"))
        XCTAssertTrue(model.seenToolNames[0].contains("read_file"))
        // search_tools 之后:browser_open 被激活,第二次 respond 模型能看到。
        XCTAssertTrue(model.seenToolNames[1].contains("browser_open"), "激活后模型应看到长尾工具:\(model.seenToolNames[1])")
        // 长尾工具真被执行。
        let invocations = await session.toolInvocations
        XCTAssertTrue(invocations.contains("browser_open"))
        // 循环恒良构。
        let violations = await session.recordedInvariantViolations
        XCTAssertTrue(violations.isEmpty, "延迟加载下循环应良构:\(violations)")
    }
}
