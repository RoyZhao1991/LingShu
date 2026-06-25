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

    /// 流式进度(修「派发 agent 交给 X 后干等没进度」):run 边跑边回调 progress 把累计输出尾部喂出来,结果含全部输出。
    func testRunStreamsProgressAndReturnsOutput() async {
        let plugin = LingShuAgentPlugin(
            id: "stream-test", displayName: "StreamTest",
            executable: "/bin/sh",
            argsTemplate: ["-c", "printf 'first '; sleep 0.05; printf 'second {{objective}}'"],
            role: .general, timeoutSeconds: 10)
        let counter = ProgressCounter()
        let result = await LingShuAgentPluginStore.run(
            plugin, objective: "DONE", workingDirectory: "/tmp",
            progress: { _ in counter.bump() })
        guard case .completed(let text) = result else {
            return XCTFail("应成功完成,实际:\(result)")
        }
        XCTAssertTrue(text.contains("first"), "结果应含先输出的部分")
        XCTAssertTrue(text.contains("second DONE"), "结果应含填好 objective 的后续输出")
        XCTAssertGreaterThan(counter.value, 0, "流式 progress 至少回调一次=看得到进度")
    }
}

/// 线程安全计数器(progress 在后台队列回调)。
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
