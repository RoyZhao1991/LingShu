import XCTest
@testable import LingShuMac

/// 完全版接缝守卫:#1 续接策略 / #4 记忆合并 / #6 能力注册表。
final class CompleteVersionSeamTests: XCTestCase {

    // MARK: #1 ModelChannel 续接策略

    func testContinuationNativeOnlyWhenSupportedAndNotRewritten() {
        // 支持原生(Responses/Codex)且没改写上下文 → native。
        XCTAssertEqual(LingShuModelChannelStrategy.mode(provider: "openai-responses", didRewriteContext: false), .native)
        XCTAssertEqual(LingShuModelChannelStrategy.mode(provider: "codex", didRewriteContext: false), .native)
        // **改写了上下文 → 强制降级 prefixStable(避开服务端续接 vs 改写冲突)。**
        XCTAssertEqual(LingShuModelChannelStrategy.mode(provider: "openai-responses", didRewriteContext: true), .prefixStable)
    }

    func testContinuationStatelessProvidersUsePrefix() {
        for p in ["deepseek", "kimi", "moonshot", "claude", "anthropic", "doubao", "qwen"] {
            XCTAssertEqual(LingShuModelChannelStrategy.mode(provider: p, didRewriteContext: false), .prefixStable, "\(p) 应走前缀稳定")
        }
        XCTAssertEqual(LingShuModelChannelStrategy.mode(provider: "some-private-raw", didRewriteContext: false), .localCompressed)
    }

    // MARK: #4 记忆合并

    func testMemoryMergeRanksDedupsLimits() {
        let g1 = [LingShuUnifiedMemoryHit(source: "graph", title: "A", snippet: "", score: 0.9),
                  LingShuUnifiedMemoryHit(source: "graph", title: "A", snippet: "", score: 0.5)]  // 同源同题去重
        let g2 = [LingShuUnifiedMemoryHit(source: "local-files", title: "B", snippet: "", score: 0.7)]
        let merged = LingShuMemoryMerge.merge([g1, g2], limit: 8)
        XCTAssertEqual(merged.map(\.title), ["A", "B"], "按分数降序")
        XCTAssertEqual(merged.count, 2, "同 source|title 去重")
        XCTAssertEqual(LingShuMemoryMerge.merge([g1, g2], limit: 1).count, 1, "limit 生效")
    }

    // MARK: #6 能力注册表

    private struct FakeProvider: LingShuCapabilityProvider {
        let caps: [LingShuCapability]
        func capabilities() -> [LingShuCapability] { caps }
    }
    func testCapabilityMergeDedupsByID() {
        let a = FakeProvider(caps: [.init(id: "ppt", description: "做PPT", source: "skill"),
                                    .init(id: "weather", description: "天气", source: "mcp")])
        let b = FakeProvider(caps: [.init(id: "ppt", description: "重复", source: "team")])  // 同 id 去重
        let merged = LingShuCapabilityRegistry.merge([a, b])
        XCTAssertEqual(Set(merged.map(\.id)), ["ppt", "weather"])
        XCTAssertEqual(merged.first { $0.id == "ppt" }?.source, "skill", "先到先得")
    }
}
