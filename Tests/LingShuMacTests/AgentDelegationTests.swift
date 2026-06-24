import XCTest
@testable import LingShuMac

/// Codex/Claude 作为委托工具的纯逻辑守卫(0 模型依赖,不真跑 CLI)。
final class AgentDelegationTests: XCTestCase {

    func testClaudeBridgeResolvesPreferredExecutable() {
        // /bin/ls 一定存在且可执行 → resolveCLIPath 应优先返回 preferred。
        XCTAssertEqual(ClaudeBridge.resolveCLIPath(preferredPath: "/bin/ls"), "/bin/ls")
    }

    func testClaudeBridgeRejectsNonexistentPreferred() {
        // 不存在的 preferred 不应被返回(会落到候选;本机没装 claude 则 nil,不崩)。
        XCTAssertNotEqual(ClaudeBridge.resolveCLIPath(preferredPath: "/nonexistent/zzz"), "/nonexistent/zzz")
    }

    func testDelegateToolsAreInCoreCatalog() {
        // 恒可见:大脑要能直接在工具清单里看到,不被延迟加载藏到 search_tools 后。
        XCTAssertTrue(LingShuToolCatalog.coreToolNames.contains("delegate_to_codex"))
        XCTAssertTrue(LingShuToolCatalog.coreToolNames.contains("delegate_to_claude"))
    }

    func testClaudeReplyResultIsSendableValue() {
        // 编译期已保证 Sendable;运行期确认 case 构造正常。
        let ok: ClaudeReplyResult = .success("done")
        if case .success(let t) = ok { XCTAssertEqual(t, "done") } else { XCTFail() }
    }
}
