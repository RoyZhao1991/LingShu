import XCTest
@testable import LingShuMac

/// agent 插件(动态注册的 CLI agent)守卫:别名/参数填充 + 注册库读写往返。
final class AgentPluginTests: XCTestCase {

    private func sample() -> LingShuAgentPlugin {
        .init(id: "codex", displayName: "Codex", aliases: ["codex"],
              executable: "/Applications/Codex.app/Contents/Resources/codex",
              argsTemplate: ["exec", "{{objective}}"], role: .maker, subtitle: "写代码", icon: "hammer.fill")
    }

    func testResolvedArgumentsFillsObjective() {
        let p = sample()
        XCTAssertEqual(p.resolvedArguments(objective: "写个坦克大战"), ["exec", "写个坦克大战"])
    }

    func testAllAliasesDeduped() {
        let p = sample()
        XCTAssertEqual(Set(p.allAliases), Set(["Codex", "codex"]))
    }

    func testStoreRegisterLoadRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentplugin-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = sample()
        XCTAssertTrue(LingShuAgentPluginStore.register(p, into: dir))
        let loaded = LingShuAgentPluginStore.load(from: dir)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "codex")
        XCTAssertEqual(loaded.first?.argsTemplate, ["exec", "{{objective}}"])
        XCTAssertEqual(loaded.first?.role, .maker)
        // 注销
        XCTAssertTrue(LingShuAgentPluginStore.unregister(id: "codex", from: dir))
        XCTAssertEqual(LingShuAgentPluginStore.load(from: dir).count, 0)
    }
}
