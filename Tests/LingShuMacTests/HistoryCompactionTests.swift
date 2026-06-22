import XCTest
@testable import LingShuMac

/// 差距4·上下文压缩可替换模块的纯逻辑守卫:
/// ① token 估算器 CJK/ASCII 量级合理;② 分层压缩器:未超预算→nil(不动);超预算→压缩且最近段逐字保留、
/// 系统消息全留、不留孤儿 tool 结果、压缩后 token 在预算内;③ 蒸馏标记解析(@@SUMMARY@@/@@FACTS@@);
/// ④ 关键事实被抽出(供知识图谱无损召回)。
final class HistoryCompactionTests: XCTestCase {

    private func msg(_ role: LingShuAgentRole, _ content: String, calls: [LingShuAgentToolCall] = [], toolCallID: String? = nil) -> LingShuAgentMessage {
        LingShuAgentMessage(role: role, content: content, toolCalls: calls, toolCallID: toolCallID)
    }

    // MARK: token 估算

    func testTokenEstimatorMagnitudes() {
        XCTAssertEqual(LingShuTokenEstimator.estimate(""), 0)
        // 10 个汉字 ≈ 10 token;40 个 ascii ≈ 10 token。量级而非精确。
        XCTAssertEqual(LingShuTokenEstimator.estimate("一二三四五六七八九十"), 10)
        let ascii = String(repeating: "a", count: 40)
        XCTAssertEqual(LingShuTokenEstimator.estimate(ascii), 10)
    }

    // MARK: 分层压缩

    func testLayeredReturnsNilWhenUnderBudget() async {
        let model = LingShuScriptedAgentModel([.text("不该被调用")])
        let compactor = LingShuLayeredCompactor(tokenBudget: 100_000, keepRecentTokens: 8_000)
        let messages = [msg(.system, "身份"), msg(.user, "你好"), msg(.assistant, "在")]
        let result = await compactor.compact(messages: messages, model: model)
        XCTAssertNil(result, "未超预算不应压缩")
    }

    func testLayeredCompactsAndKeepsRecentAndSystem() async {
        let model = LingShuScriptedAgentModel([.text("@@SUMMARY@@\n早段要点:决策X;文件 /tmp/a.txt\n@@FACTS@@\n产出物 /tmp/a.txt 已生成\n用户偏好简体中文")])
        // 小预算 + 小 keepRecent,逼出压缩。每条正文给足 token。
        let big = String(repeating: "这是一段很长的早期对话内容需要被压缩掉", count: 20)
        var messages: [LingShuAgentMessage] = [msg(.system, "系统身份永留")]
        for i in 0..<10 { messages.append(msg(i % 2 == 0 ? .user : .assistant, "\(big)#\(i)")) }
        let recentMarker = "最近这条必须逐字保留XYZ"
        messages.append(msg(.user, recentMarker))

        let compactor = LingShuLayeredCompactor(tokenBudget: 200, keepRecentTokens: 80)
        let result = await compactor.compact(messages: messages, model: model)
        let r = try! XCTUnwrap(result)

        // 系统消息仍在首位且原文保留。
        XCTAssertEqual(r.messages.first?.role, .system)
        XCTAssertEqual(r.messages.first?.content, "系统身份永留")
        // 出现了前情提要。
        XCTAssertTrue(r.messages.contains { $0.content.contains("前情提要") })
        // 最近一条逐字保留。
        XCTAssertTrue(r.messages.contains { $0.content.contains(recentMarker) })
        // 压缩后比原来短。
        XCTAssertLessThan(r.messages.count, messages.count)
        // 抽出了事实(供 remember 进图谱)。
        XCTAssertFalse(r.extractedFacts.isEmpty)
        XCTAssertTrue(r.extractedFacts.contains { $0.contains("/tmp/a.txt") })
    }

    func testLayeredNoOrphanToolResultAtHead() async {
        let model = LingShuScriptedAgentModel([.text("@@SUMMARY@@\n提要\n@@FACTS@@\n")])
        let big = String(repeating: "长内容压缩素材", count: 30)
        var messages: [LingShuAgentMessage] = [msg(.system, "S")]
        // 构造保留段开头恰是 tool 结果的情形:压缩器必须把孤儿 tool 丢掉。
        for i in 0..<8 { messages.append(msg(.user, "\(big)#\(i)")) }
        messages.append(msg(.assistant, "", calls: [LingShuAgentToolCall(id: "c1", name: "t", argumentsJSON: "{}")]))
        messages.append(msg(.tool, "工具结果", toolCallID: "c1"))
        messages.append(msg(.user, "尾部"))

        let compactor = LingShuLayeredCompactor(tokenBudget: 150, keepRecentTokens: 30)
        let result = await compactor.compact(messages: messages, model: model)
        let r = try! XCTUnwrap(result)
        // body 第一条(系统之后)绝不能是孤儿 tool 结果。
        let firstBody = r.messages.first { $0.role != .system }
        XCTAssertNotEqual(firstBody?.role, .tool, "压缩后开头不能留孤儿 tool 结果")
    }

    func testLayeredFallsBackOnDistillFailure() async {
        // 模型返回空 → 蒸馏失败 → 仍要返回(仅硬保留最近段),绝不卡住。
        let model = LingShuScriptedAgentModel([.text("")])
        let big = String(repeating: "素材", count: 60)
        var messages: [LingShuAgentMessage] = [msg(.system, "S")]
        for i in 0..<10 { messages.append(msg(.user, "\(big)#\(i)")) }
        let compactor = LingShuLayeredCompactor(tokenBudget: 100, keepRecentTokens: 40)
        let result = await compactor.compact(messages: messages, model: model)
        let r = try! XCTUnwrap(result)
        XCTAssertLessThan(r.messages.count, messages.count)
        XCTAssertTrue(r.extractedFacts.isEmpty)
    }

    // MARK: 蒸馏标记解析

    func testDistillerParseSummaryAndFacts() {
        let raw = "@@SUMMARY@@\n这是提要正文\n@@FACTS@@\n- 事实一\n- 事实二\n* 事实三"
        let d = try! XCTUnwrap(LingShuCompactionDistiller.parse(raw))
        XCTAssertEqual(d.summary, "这是提要正文")
        XCTAssertEqual(d.facts, ["事实一", "事实二", "事实三"])
    }

    func testDistillerParseSummaryOnly() {
        let d = try! XCTUnwrap(LingShuCompactionDistiller.parse("@@SUMMARY@@\n只有提要没有事实段"))
        XCTAssertEqual(d.summary, "只有提要没有事实段")
        XCTAssertTrue(d.facts.isEmpty)
    }

    func testDistillerParseNoMarkerTreatsAllAsSummary() {
        let d = try! XCTUnwrap(LingShuCompactionDistiller.parse("模型没按格式,整段当提要"))
        XCTAssertEqual(d.summary, "模型没按格式,整段当提要")
        XCTAssertTrue(d.facts.isEmpty)
    }

    func testDistillerParseEmptyReturnsNil() {
        XCTAssertNil(LingShuCompactionDistiller.parse("   \n  "))
    }

    // MARK: 经典压缩器(默认兜底)与原行为对齐

    func testMessageCountCompactorNilUnderLimit() async {
        let model = LingShuScriptedAgentModel([.text("提要")])
        let compactor = LingShuMessageCountCompactor(maxHistoryMessages: 10)
        let messages = [msg(.system, "S"), msg(.user, "1"), msg(.assistant, "2")]
        let result = await compactor.compact(messages: messages, model: model)
        XCTAssertNil(result)
    }

    func testMessageCountCompactorCompactsOverLimit() async {
        let model = LingShuScriptedAgentModel([.text("早段提要")])
        let compactor = LingShuMessageCountCompactor(maxHistoryMessages: 4)
        var messages: [LingShuAgentMessage] = [msg(.system, "S")]
        for i in 0..<10 { messages.append(msg(.user, "m\(i)")) }
        let result = await compactor.compact(messages: messages, model: model)
        let r = try! XCTUnwrap(result)
        XCTAssertTrue(r.messages.contains { $0.content.contains("前情提要") })
        XCTAssertEqual(r.messages.first?.role, .system)
    }
}
