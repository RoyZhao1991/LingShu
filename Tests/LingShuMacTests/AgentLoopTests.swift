import XCTest
@testable import LingShuMac

/// 脚本化 mock 模型:按预设序列逐轮返回(工具调用或文本),用于脱网测试编排循环。
private final class ScriptedAgentModel: LingShuAgentModel, @unchecked Sendable {
    private let script: [LingShuAgentModelResponse]
    private var index = 0
    private(set) var sawToolResults: [String] = []

    init(_ script: [LingShuAgentModelResponse]) { self.script = script }

    // 由 LingShuAgentSession(actor)串行调用,无并发,无需加锁。
    func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
        // 记录上一轮回灌的工具结果,证明结果确实回到了模型上下文。
        if let last = messages.last, last.role == .tool {
            sawToolResults.append(last.content)
        }
        defer { index += 1 }
        return index < script.count ? script[index] : .text("(脚本耗尽)")
    }
}

final class AgentLoopTests: XCTestCase {

    func testModelCallsToolThenFinishes() async {
        let model = ScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "search", argumentsJSON: "{\"q\":\"灵枢\"}")]),
            .text("已根据检索结果作答")
        ])
        let searchTool = LingShuAgentTool(name: "search", description: "检索") { _ in "检索结果:命中3条" }
        let session = LingShuAgentSession(id: "s1", tools: [searchTool], model: model)

        let result = await session.send("查一下灵枢")
        XCTAssertEqual(result, .completed(text: "已根据检索结果作答"))
        let invocations = await session.toolInvocations
        XCTAssertEqual(invocations, ["search"])
        // 工具结果确实回灌进了模型上下文。
        XCTAssertEqual(model.sawToolResults, ["检索结果:命中3条"])
    }

    func testMultipleToolsInOneTurnExecuteInOrder() async {
        let model = ScriptedAgentModel([
            .toolCalls([
                .init(id: "c1", name: "a", argumentsJSON: "{}"),
                .init(id: "c2", name: "b", argumentsJSON: "{}")
            ]),
            .text("两个工具都跑完了")
        ])
        let toolA = LingShuAgentTool(name: "a", description: "A") { _ in "A-ok" }
        let toolB = LingShuAgentTool(name: "b", description: "B") { _ in "B-ok" }
        let session = LingShuAgentSession(id: "s2", tools: [toolA, toolB], model: model)

        let result = await session.send("做 A 和 B")
        XCTAssertEqual(result, .completed(text: "两个工具都跑完了"))
        let invocations = await session.toolInvocations
        XCTAssertEqual(invocations, ["a", "b"])
    }

    func testUnknownToolFeedsBackError() async {
        let model = ScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "ghost", argumentsJSON: "{}")]),
            .text("已处理未知工具")
        ])
        let session = LingShuAgentSession(id: "s3", tools: [], model: model)
        let result = await session.send("调一个不存在的工具")
        XCTAssertEqual(result, .completed(text: "已处理未知工具"))
        XCTAssertTrue(model.sawToolResults.first?.contains("未知工具") ?? false)
    }

    func testPlainAnswerNoTools() async {
        let model = ScriptedAgentModel([.text("你好，我是灵枢")])
        let session = LingShuAgentSession(id: "s4", tools: [], model: model)
        let result = await session.send("你好")
        XCTAssertEqual(result, .completed(text: "你好，我是灵枢"))
        let invocations = await session.toolInvocations
        XCTAssertTrue(invocations.isEmpty)
    }

    func testMaxTurnsGuardStopsRunawayLoop() async {
        // 模型每轮都要调工具、永不收尾 → 应在 maxTurns 处停。
        let loopingScript = Array(repeating: LingShuAgentModelResponse.toolCalls([.init(id: "c", name: "noop", argumentsJSON: "{}")]), count: 50)
        let model = ScriptedAgentModel(loopingScript)
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "ok" }
        let session = LingShuAgentSession(id: "s5", tools: [noop], model: model, maxTurns: 3)
        let result = await session.send("无限循环")
        if case .maxTurnsReached = result {
            let used = await session.turnsUsed
            XCTAssertEqual(used, 3)
        } else {
            XCTFail("应触发 maxTurns 守卫")
        }
    }

    func testStuckRepeatHandsBackBeforeCeiling() async {
        // 目标驱动:模型连续发起完全相同的工具调用=原地打转,应在停滞阈值处诚实交还,
        // 而不是空转到(高位)安全天花板。证明停止位是"停滞",不是固定轮数预算。
        let spinScript = Array(repeating: LingShuAgentModelResponse.toolCalls([.init(id: "c", name: "noop", argumentsJSON: "{\"q\":\"same\"}")]), count: 50)
        let model = ScriptedAgentModel(spinScript)
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "still stuck" }
        let session = LingShuAgentSession(id: "s7", tools: [noop], model: model, maxTurns: 40)
        let result = await session.send("原地打转")
        guard case .maxTurnsReached = result else { return XCTFail("停滞应触发交还") }
        let used = await session.turnsUsed
        XCTAssertEqual(used, LingShuAgentSession.stuckRepeatThreshold, "应在停滞阈值处停,而非跑满天花板")
        XCTAssertLessThan(used, 40, "停止位是停滞检测,不是 maxTurns 天花板")
    }

    func testToolReceivesArgumentsJSON() async {
        let model = ScriptedAgentModel([
            .toolCalls([.init(id: "c1", name: "echo", argumentsJSON: "{\"text\":\"在\"}")]),
            .text("done")
        ])
        let captured = ArgsBox()
        let echo = LingShuAgentTool(name: "echo", description: "回显") { args in
            await captured.set(args)
            return "ok"
        }
        let session = LingShuAgentSession(id: "s6", tools: [echo], model: model)
        _ = await session.send("回显")
        let got = await captured.value
        XCTAssertEqual(got, "{\"text\":\"在\"}")
    }
}

private actor ArgsBox {
    private(set) var value: String = ""
    func set(_ v: String) { value = v }
}
