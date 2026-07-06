import XCTest
@testable import LingShuMac

/// 差距7-A·工具调度可替换模块的纯逻辑守卫:
/// ① 串行/并行**结果恒与输入同序**(协议契约,lastText/可观测确定);② 未知工具确定性错误文本;
/// ③ 并行实现**确实并发**(峰值并发 > 1),串行实现**恒不并发**(峰值 = 1);④ 空/单调用边界。
final class ToolDispatchTests: XCTestCase {

    /// 记录"同时在跑的工具数"峰值的探针(actor 安全)。用于区分并行/串行,不靠脆的墙钟计时。
    private actor ConcurrencyProbe {
        private var running = 0
        private(set) var peak = 0
        func enter() { running += 1; peak = max(peak, running) }
        func leave() { running -= 1 }
    }

    private func call(_ id: String, _ name: String, _ args: String = "{}") -> LingShuAgentToolCall {
        LingShuAgentToolCall(id: id, name: name, argumentsJSON: args)
    }

    /// 一个会"占用一小段时间"的工具(给并发留出重叠窗口),返回固定文本。
    private func probedTool(
        _ name: String,
        probe: ConcurrencyProbe,
        output: String,
        metadata: LingShuToolMetadata? = nil
    ) -> LingShuAgentTool {
        LingShuAgentTool(name: name, description: "", metadata: metadata) { _ in
            await probe.enter()
            try? await Task.sleep(nanoseconds: 40_000_000)   // 40ms 重叠窗口
            await probe.leave()
            return output
        }
    }

    // MARK: 结果同序(串行 + 并行都必须保证)

    func testSerialPreservesOrder() async {
        let tools = [
            LingShuAgentTool(name: "a", description: "") { _ in "A" },
            LingShuAgentTool(name: "b", description: "") { _ in "B" },
            LingShuAgentTool(name: "c", description: "") { _ in "C" },
        ]
        let calls = [call("1", "a"), call("2", "b"), call("3", "c")]
        let out = await LingShuSerialToolDispatcher().dispatch(calls, tools: tools)
        XCTAssertEqual(out.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(out.map(\.output), ["A", "B", "C"])
    }

    func testParallelPreservesOrderDespiteConcurrency() async {
        let probe = ConcurrencyProbe()
        // 故意让"先发起"的工具睡更久——若按完成顺序返回会乱序,断言它仍按发起顺序。
        let tools = [
            LingShuAgentTool(name: "slow", description: "") { _ in try? await Task.sleep(nanoseconds: 60_000_000); return "SLOW" },
            LingShuAgentTool(name: "fast", description: "") { _ in "FAST" },
        ]
        _ = probe
        let calls = [call("1", "slow"), call("2", "fast")]
        let out = await LingShuParallelToolDispatcher().dispatch(calls, tools: tools)
        XCTAssertEqual(out.map(\.id), ["1", "2"], "并行也必须按发起顺序返回")
        XCTAssertEqual(out.map(\.output), ["SLOW", "FAST"])
    }

    // MARK: 并行确实并发 / 串行确实不并发

    func testParallelActuallyRunsConcurrently() async {
        let probe = ConcurrencyProbe()
        let tools = [
            probedTool("a", probe: probe, output: "A"),
            probedTool("b", probe: probe, output: "B"),
            probedTool("c", probe: probe, output: "C"),
        ]
        let calls = [call("1", "a"), call("2", "b"), call("3", "c")]
        _ = await LingShuParallelToolDispatcher().dispatch(calls, tools: tools)
        let peak = await probe.peak
        XCTAssertGreaterThan(peak, 1, "并行调度应有 >1 个工具同时在跑(实测峰值=\(peak))")
    }

    func testParallelDispatcherFallsBackToSerialForSideEffectTools() async {
        let probe = ConcurrencyProbe()
        let writeMetadata = LingShuToolMetadata(effect: .write, parallelPolicy: .serial)
        let tools = [
            probedTool("write_a", probe: probe, output: "A", metadata: writeMetadata),
            probedTool("write_b", probe: probe, output: "B", metadata: writeMetadata),
            probedTool("write_c", probe: probe, output: "C", metadata: writeMetadata),
        ]
        let calls = [call("1", "write_a"), call("2", "write_b"), call("3", "write_c")]
        let out = await LingShuParallelToolDispatcher().dispatch(calls, tools: tools)
        let peak = await probe.peak
        XCTAssertEqual(out.map(\.output), ["A", "B", "C"])
        XCTAssertEqual(peak, 1, "副作用工具声明 serial 后,并行调度器也必须回退串行")
    }

    func testSerialNeverRunsConcurrently() async {
        let probe = ConcurrencyProbe()
        let tools = [
            probedTool("a", probe: probe, output: "A"),
            probedTool("b", probe: probe, output: "B"),
            probedTool("c", probe: probe, output: "C"),
        ]
        let calls = [call("1", "a"), call("2", "b"), call("3", "c")]
        _ = await LingShuSerialToolDispatcher().dispatch(calls, tools: tools)
        let peak = await probe.peak
        XCTAssertEqual(peak, 1, "串行调度峰值并发必须恒为 1")
    }

    // MARK: 未知工具 + 边界

    func testUnknownToolDeterministicError() async {
        let out = await LingShuParallelToolDispatcher().dispatch([call("9", "nope")], tools: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].output, "错误:未知工具 nope")
    }

    func testEmptyAndSingle() async {
        let empty = await LingShuParallelToolDispatcher().dispatch([], tools: [])
        XCTAssertTrue(empty.isEmpty)
        let one = await LingShuParallelToolDispatcher().dispatch(
            [call("1", "x")],
            tools: [LingShuAgentTool(name: "x", description: "") { _ in "X" }]
        )
        XCTAssertEqual(one.map(\.output), ["X"])
    }

    /// 串行/并行对同一输入**结果完全等价**(可无损互换的根本保证)。
    func testSerialParallelEquivalentResults() async {
        let tools = [
            LingShuAgentTool(name: "a", description: "") { _ in "A" },
            LingShuAgentTool(name: "b", description: "") { _ in "B" },
            LingShuAgentTool(name: "c", description: "") { _ in "C" },
        ]
        let calls = [call("1", "a"), call("2", "b"), call("3", "c"), call("4", "missing")]
        let s = await LingShuSerialToolDispatcher().dispatch(calls, tools: tools)
        let p = await LingShuParallelToolDispatcher().dispatch(calls, tools: tools)
        XCTAssertEqual(s, p)
    }
}
