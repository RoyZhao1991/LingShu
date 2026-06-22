import XCTest
@testable import LingShuMac

/// 完全版骨架 #2 守卫:统一 `LingShuHarnessConfig`(脑力自适应:并行/压缩/延迟加载),
/// 且 **nested 的 spine 经它建会话、吃齐与 .classic 同一套**(消除双底盘不一致)。
final class NestedHarnessTests: XCTestCase {

    private func tool(_ name: String, _ desc: String = "d", out: String = "ok") -> LingShuAgentTool {
        LingShuAgentTool(name: name, description: desc) { _ in out }
    }

    /// 记录每次 respond 收到的工具名,验证活跃集是否被自适应裁剪。
    private final class RecordingModel: LingShuAgentModel, @unchecked Sendable {
        private let script: [LingShuAgentModelResponse]; private var i = 0
        private(set) var seen: [[String]] = []
        init(_ s: [LingShuAgentModelResponse]) { script = s }
        func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
            seen.append(tools.map(\.name)); defer { i += 1 }
            return i < script.count ? script[i] : .text("(脚本耗尽)")
        }
    }

    // MARK: 配置纯方法

    func testConfigDispatcherAndCompactor() {
        let parallel = LingShuHarnessConfig(serialDispatch: false)
        XCTAssertTrue(parallel.dispatcher() is LingShuParallelToolDispatcher)
        XCTAssertTrue(LingShuHarnessConfig(serialDispatch: true).dispatcher() is LingShuSerialToolDispatcher)
        // 压缩只对 maxHistory>0 启用;0=短命会话不压缩。
        XCTAssertNil(parallel.compactor(maxHistoryMessages: 0))
        XCTAssertNotNil(parallel.compactor(maxHistoryMessages: 40))
        XCTAssertTrue(LingShuHarnessConfig(classicCompact: true).compactor(maxHistoryMessages: 40) is LingShuMessageCountCompactor)
    }

    func testConfigCatalogAdaptive() {
        // 非延迟:全暴露。
        let eager = LingShuHarnessConfig(deferredCatalog: false)
        let tools = [tool("read_file"), tool("browser_open")]
        XCTAssertNil(eager.applyCatalog(tools).exposed)
        // 延迟(强脑档):核心集 + search_tools,长尾延迟。需工具数 > 核心集才触发。
        let core = LingShuToolCatalog.coreToolNames.map { tool($0) }
        let deferred = LingShuHarnessConfig(deferredCatalog: true)
        let r = deferred.applyCatalog(core + [tool("browser_open")])
        XCTAssertNotNil(r.exposed)
        XCTAssertTrue(r.exposed!.contains("recall_local"), "基础能力恒暴露")
        XCTAssertFalse(r.exposed!.contains("browser_open"), "长尾延迟到 search_tools")
    }

    // MARK: nested spine 吃齐自适应 harness(端到端)

    func testNestedSpineUsesAdaptiveCatalog() async {
        // 强脑延迟档 + 一批工具(核心集 + 长尾 browser_open)。
        let tools = LingShuToolCatalog.coreToolNames.map { tool($0) } + [tool("browser_open", "浏览器")]
        let harness = LingShuHarnessConfig(deferredCatalog: true)
        let model = RecordingModel([.text("好")])   // 简单请求 → spine 直通
        let nested = LingShuNestedAgentSession(
            id: "n", system: "你是测试体", initialMessages: [], tools: tools, model: model,
            maxTurns: 5, maxHistoryMessages: 20, blockingToolNames: ["ask_user"],
            acceptStage: { _, r, _ in r }, note: { _, _ in }, setPhase: { _ in },
            isInterrupted: { false }, consumeInterrupt: { }, harness: harness
        )
        _ = await nested.send("你好")
        XCTAssertFalse(model.seen.isEmpty, "spine 应至少调一次模型")
        // spine 经统一 harness 建 → 延迟加载生效:模型看到 search_tools,看不到长尾 browser_open。
        XCTAssertTrue(model.seen[0].contains("search_tools"), "spine 应吃到延迟加载(有 search_tools):\(model.seen[0])")
        XCTAssertFalse(model.seen[0].contains("browser_open"), "长尾工具应被延迟,不直接暴露给 spine")
    }

    func testNestedNoHarnessFallsBackToBareSession() async {
        // harness=nil(测试默认/向后兼容):spine 用裸会话,全工具暴露。
        let tools = [tool("read_file"), tool("browser_open")]
        let model = RecordingModel([.text("好")])
        let nested = LingShuNestedAgentSession(
            id: "n2", system: "s", initialMessages: [], tools: tools, model: model,
            maxTurns: 5, maxHistoryMessages: 0, blockingToolNames: ["ask_user"],
            acceptStage: { _, r, _ in r }, note: { _, _ in }, setPhase: { _ in },
            isInterrupted: { false }, consumeInterrupt: { }
        )
        _ = await nested.send("你好")
        XCTAssertTrue(model.seen[0].contains("browser_open"), "无 harness 时全暴露(兼容)")
    }
}
