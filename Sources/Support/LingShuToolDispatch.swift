import Foundation

/// 差距7-A·**工具调度可替换模块**:一次模型回合吐出的多个 tool_call 如何被执行。
///
/// 设计取向(与 `LingShuAgentSessioning` 同一套路:协议 + 多实现 + 单一切换点 `makeAgentSession`):
/// 把"执行一组 tool_call"抽成协议,默认串行(经典行为、零变更),并行实现用 `TaskGroup` 同时跑。
/// **同一回合的多个 tool_call 是模型一次性发出的 → 天然互不依赖 → 并行安全**(这正是 Codex/CC 的通用契约,
/// 不做 per-case 依赖分析,保持通用零定制)。结果**与输入同序**返回,由实现保证,调用方据此补 tool 结果保持
/// OpenAI 协议良构(每个 tool_call 必有同 id 的 tool 响应)。将来有更好的调度(如带依赖图/优先级)直接换实现。
///
/// 纯逻辑、无 actor 状态、可单测(注入带可控延迟的工具断言"并行确实并发 + 结果恒同序")。

/// 单次 tool_call 的执行结果(与发起调用同 id/同 name,output 为工具返回文本)。
struct LingShuToolCallOutcome: Sendable, Equatable {
    let id: String
    let name: String
    let output: String
}

/// 工具调度协议:执行一组调用,返回**与输入同序**的结果。顺序保证是协议契约(便于 lastText/可观测确定)。
protocol LingShuToolDispatching: Sendable {
    func dispatch(_ calls: [LingShuAgentToolCall], tools: [LingShuAgentTool]) async -> [LingShuToolCallOutcome]
}

extension LingShuToolDispatching {
    /// 共享执行核:按名解析工具→调 handler;未知工具给确定性错误文本(与经典循环逐字一致,行为零变更)。
    func execute(_ call: LingShuAgentToolCall, tools: [LingShuAgentTool]) async -> LingShuToolCallOutcome {
        let output: String
        if let tool = tools.first(where: { $0.name == call.name }) {
            output = await tool.handler(call.argumentsJSON)
        } else {
            output = "错误:未知工具 \(call.name)"
        }
        return LingShuToolCallOutcome(id: call.id, name: call.name, output: output)
    }
}

/// 默认实现:**串行**逐个执行(经典循环原行为,零变更)。测试默认走它=确定性。
struct LingShuSerialToolDispatcher: LingShuToolDispatching {
    func dispatch(_ calls: [LingShuAgentToolCall], tools: [LingShuAgentTool]) async -> [LingShuToolCallOutcome] {
        var out: [LingShuToolCallOutcome] = []
        out.reserveCapacity(calls.count)
        for call in calls {
            out.append(await execute(call, tools: tools))
        }
        return out
    }
}

/// 超越实现:**并行**(差距7 降延迟)。同回合无依赖 tool_call 用 `TaskGroup` 并发跑,
/// 按原始下标收集后**复原输入顺序**返回(并发只影响时序,不影响结果顺序=确定性)。
/// 单个调用直接串行(免 TaskGroup 开销),0 个返回空。
struct LingShuParallelToolDispatcher: LingShuToolDispatching {
    func dispatch(_ calls: [LingShuAgentToolCall], tools: [LingShuAgentTool]) async -> [LingShuToolCallOutcome] {
        guard calls.count > 1 else {
            if let only = calls.first { return [await execute(only, tools: tools)] }
            return []
        }
        let indexed: [(Int, LingShuToolCallOutcome)] = await withTaskGroup(
            of: (Int, LingShuToolCallOutcome).self
        ) { group in
            for (i, call) in calls.enumerated() {
                group.addTask { (i, await execute(call, tools: tools)) }
            }
            var collected: [(Int, LingShuToolCallOutcome)] = []
            collected.reserveCapacity(calls.count)
            for await pair in group { collected.append(pair) }
            return collected
        }
        return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
