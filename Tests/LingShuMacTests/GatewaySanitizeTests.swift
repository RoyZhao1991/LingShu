import XCTest
@testable import LingShuMac

/// 网关序列化前「自愈消息结构」双向守卫(测无可测·取消→孤儿→400 修复)。
/// 真机实锤:硬取消/seeding 会留下**孤儿 tool 结果**(无对应 assistant tool_calls),旧 sanitizer 只补"缺结果"、
/// 不丢"孤儿结果",溜到 DeepSeek 网关即 400「tool must follow tool_calls」。这里守住双向良构。
final class GatewaySanitizeTests: XCTestCase {

    private func asst(_ content: String, calls: [(String, String)] = []) -> LingShuModelMessage {
        LingShuModelMessage(role: "assistant", content: content,
                            toolCalls: calls.isEmpty ? nil : calls.map { LingShuToolCall(id: $0.0, name: $0.1, arguments: "{}") })
    }
    private func tool(_ id: String, _ content: String = "结果") -> LingShuModelMessage {
        LingShuModelMessage(role: "tool", content: content, toolCallID: id)
    }
    private func user(_ c: String) -> LingShuModelMessage { LingShuModelMessage(role: "user", content: c) }

    /// 良构断言:每条 tool 结果的 id 必有更早 assistant 声明;每个 assistant 调用都被应答。
    private func assertWellFormed(_ msgs: [LingShuModelMessage], file: StaticString = #filePath, line: UInt = #line) {
        var declared = Set<String>(); var answered = Set<String>(); var openCalls: [String] = []
        for m in msgs {
            switch m.role {
            case "assistant" where (m.toolCalls?.isEmpty == false):
                for id in openCalls where !answered.contains(id) { XCTFail("未应答调用 \(id)", file: file, line: line) }
                openCalls = m.toolCalls!.map(\.id); m.toolCalls!.forEach { declared.insert($0.id) }
            case "tool":
                let id = m.toolCallID ?? ""
                XCTAssertTrue(declared.contains(id), "孤儿 tool 结果未被清除:\(id)", file: file, line: line)
                answered.insert(id); openCalls.removeAll { $0 == id }
            default:
                for id in openCalls where !answered.contains(id) { XCTFail("未应答调用 \(id)", file: file, line: line) }
                openCalls = []
            }
        }
        for id in openCalls where !answered.contains(id) { XCTFail("结尾未应答调用 \(id)", file: file, line: line) }
    }

    func testOrphanToolResultIsDropped() {
        // 没有任何 assistant tool_calls,却有一条 tool 结果 → 必须被丢弃(就是 400 的根因)。
        let input = [user("做点事"), tool("ghost", "悬空结果"), asst("完成")]
        let out = LingShuGatewayAgentModel.sanitizeToolCallSequence(input)
        XCTAssertFalse(out.contains { $0.role == "tool" && $0.toolCallID == "ghost" }, "孤儿 tool 结果应被丢弃")
        assertWellFormed(out)
    }

    func testDanglingCallGetsPlaceholder() {
        // assistant 发起调用但没补结果 → 补占位(保留旧行为)。
        let input = [user("x"), asst("", calls: [("c1", "search")]), asst("以为做完了")]
        let out = LingShuGatewayAgentModel.sanitizeToolCallSequence(input)
        XCTAssertTrue(out.contains { $0.role == "tool" && $0.toolCallID == "c1" }, "缺结果的调用应补占位")
        assertWellFormed(out)
    }

    func testWellFormedUnchangedShape() {
        let input = [user("x"), asst("", calls: [("c1", "t")]), tool("c1"), asst("完成")]
        let out = LingShuGatewayAgentModel.sanitizeToolCallSequence(input)
        assertWellFormed(out)
        XCTAssertEqual(out.count, input.count, "良构序列不该增删")
    }

    func testOrphanAfterValidPairDropped() {
        // 合法对之后又冒出一条未声明 id 的 tool 结果(取消/裁剪残留)→ 丢弃。
        let input = [asst("", calls: [("c1", "t")]), tool("c1"), tool("c2", "未声明的残留"), user("继续")]
        let out = LingShuGatewayAgentModel.sanitizeToolCallSequence(input)
        XCTAssertFalse(out.contains { $0.toolCallID == "c2" }, "未声明 id 的残留 tool 结果应丢")
        assertWellFormed(out)
    }

    func testCancelLikeSequenceStaysValid() {
        // 模拟硬取消:assistant 发起两调用,只补了一个结果,后面又接了 user(打断) + 一条孤儿。
        let input = [
            asst("", calls: [("a", "write"), ("b", "run")]),
            tool("a", "已写"),
            user("停"),
            tool("b", "迟到的结果——此刻已是孤儿(前面被 user 截断)"),
            user("你是谁"),
        ]
        let out = LingShuGatewayAgentModel.sanitizeToolCallSequence(input)
        assertWellFormed(out)   // 关键:不会把 400 发出去
    }
}
