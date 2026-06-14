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

    func testBoundedHistoryTrimsOldTurnsButKeepsSystemAndLatest() async {
        // 常驻会话设了历史窗口:多轮后旧上下文在回合边界被裁,系统身份恒保留、最近一轮恒保留——
        // 杜绝旧任务无限堆积污染新请求(根因 1a)。
        let model = ScriptedAgentModel([])   // 每轮返回"(脚本耗尽)"文本 → 单轮收尾
        let session = LingShuAgentSession(id: "trim", system: "系统身份", tools: [], model: model, maxHistoryMessages: 4)
        for i in 0..<10 { _ = await session.send("第\(i)轮") }

        let msgs = await session.messages
        XCTAssertEqual(msgs.first?.role, .system, "系统消息恒在最前")
        let body = msgs.filter { $0.role != .system }
        XCTAssertLessThanOrEqual(body.count, 6, "非系统历史被裁到窗口附近(窗口4 + 当轮 user+assistant)")
        XCTAssertNotEqual(body.first?.role, .tool, "裁剪后不留孤儿 tool 结果")
        XCTAssertTrue(msgs.contains { $0.content == "第9轮" }, "最近一轮永远保留")
        XCTAssertFalse(msgs.contains { $0.content == "第0轮" }, "最早的旧轮已被裁掉")
    }

    func testMidFlightCorrectionSteersTheLoop() async {
        // 模拟用户看到 agent 跑偏后中途纠正:循环在回合边界采纳纠正,模型下一步据此改方向。
        final class InjectingModel: LingShuAgentModel, @unchecked Sendable {
            weak var session: LingShuAgentSession?
            var step = 0
            private(set) var sawCorrection = false
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .user && $0.content.contains("改用 markdown") }) {
                    sawCorrection = true
                    return .text("已按你的纠正改用 markdown 重做完成")
                }
                step += 1
                if step == 1 {
                    // 第 1 步:模拟用户中途下达纠正(干预),同时模型还在按错方向继续。
                    await session?.injectCorrection("方向不对,改用 markdown")
                    return .toolCalls([.init(id: "c1", name: "noop", argumentsJSON: "{}")])
                }
                return .text("（按错误方向收尾）")
            }
        }
        let model = InjectingModel()
        let noop = LingShuAgentTool(name: "noop", description: "空转") { _ in "ok" }
        let session = LingShuAgentSession(id: "fix", tools: [noop], model: model)
        model.session = session

        let result = await session.send("做个东西")
        XCTAssertEqual(result, .completed(text: "已按你的纠正改用 markdown 重做完成"))
        XCTAssertTrue(model.sawCorrection, "纠正应在回合边界注入,模型下一步能看到")
        let messages = await session.messages
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content.contains("最高优先级") && $0.content.contains("改用 markdown") },
                      "纠正应作为最高优先级 user 指令注入上下文")
    }

    func testSubtaskBriefingSyncsToMainThreadOnNextTurn() async {
        // 子任务完成 → 简报回灌主线程:下一回合作为 system 提示注入(信息同步,非完整上下文)。
        final class CaptureModel: LingShuAgentModel, @unchecked Sendable {
            private(set) var sawBriefing = false
            func respond(messages: [LingShuAgentMessage], tools: [LingShuAgentTool]) async -> LingShuAgentModelResponse {
                if messages.contains(where: { $0.role == .system && $0.content.contains("子任务进展简报") && $0.content.contains("抓取100条") }) {
                    sawBriefing = true
                }
                return .text("ok")
            }
        }
        let model = CaptureModel()
        let session = LingShuAgentSession(id: "main", tools: [], model: model)
        await session.injectBriefing("子任务「爬虫」已完成:抓取100条")
        _ = await session.send("接着干")
        XCTAssertTrue(model.sawBriefing, "子任务简报应在下一回合以 system 提示同步进主线程上下文")
    }

    func testTaskDeliveryReplyClassification() {
        // 任务交付报告(声称产出文件/含代码/含路径)→ 念摘要;干净对话/汇报正文 → 念全文。
        XCTAssertTrue(LingShuState.replyLooksLikeTaskDelivery("已生成 /Users/x/a.pptx,共 10 页。"))
        XCTAssertTrue(LingShuState.replyLooksLikeTaskDelivery("脚本如下:\n```python\nprint(1)\n```"))
        XCTAssertFalse(LingShuState.replyLooksLikeTaskDelivery("我是灵枢,由 Roy Zhao 打造,很高兴见到你。"))
        XCTAssertFalse(LingShuState.replyLooksLikeTaskDelivery("今天的会议要点是:先对齐目标,再分工推进,最后定下周复盘时间。"))
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
