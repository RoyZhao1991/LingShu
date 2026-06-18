import XCTest
@testable import LingShuMac

// MARK: - P3 沙箱配置生成(纯)

final class PluginSandboxTests: XCTestCase {
    func testProfileDenyDefaultAndScopedWrite() {
        let p = LingShuPluginSandbox.profile(for: .init(fileWrite: ["/work/out"], network: [], shell: true))
        XCTAssertTrue(p.contains("(deny default)"))
        XCTAssertTrue(p.contains("(allow file-read*)"), "读放宽")
        XCTAssertTrue(p.contains("(allow file-write* (subpath \"/work/out\"))"), "只放声明的写路径")
        XCTAssertFalse(p.contains("(allow network*)"), "没声明网络 → 断网")
    }

    func testProfileWildcardWriteAndNetwork() {
        let p = LingShuPluginSandbox.profile(for: .init(fileWrite: ["*"], network: ["*"], shell: true))
        XCTAssertTrue(p.contains("(allow file-write*)"))
        XCTAssertTrue(p.contains("(allow network*)"))
    }

    func testWrappedInvokesSandboxExec() {
        let w = LingShuPluginSandbox.wrapped(executable: "/usr/bin/python3", arguments: ["x.py"], permissions: .init(fileWrite: ["/tmp"]))
        XCTAssertEqual(w.executable, "/usr/bin/sandbox-exec")
        XCTAssertEqual(w.arguments.first, "-p")
        XCTAssertTrue(w.arguments.contains("/usr/bin/python3"))
        XCTAssertTrue(w.arguments.contains("x.py"))
    }
}

// MARK: - P4 扩展运行态(纯状态)

final class PluginExtensionStateTests: XCTestCase {
    func testDefaultEnabledAndToggle() {
        var s = LingShuExtensionStateStore()
        XCTAssertTrue(s.isEnabled("a"), "没记录=默认启用")
        s.setEnabled("a", false)
        XCTAssertFalse(s.isEnabled("a"))
        s.setEnabled("a", true)
        XCTAssertTrue(s.isEnabled("a"))
    }

    func testEfficacyAndDemote() {
        var s = LingShuExtensionStateStore()
        for _ in 0..<1 { s.recordOutcome("p", success: true) }
        for _ in 0..<5 { s.recordOutcome("p", success: false) }
        XCTAssertEqual(s.record("p").successCount, 1)
        XCTAssertEqual(s.record("p").failCount, 5)
        XCTAssertTrue(s.shouldDemote("p"), "样本≥5 且成功率<1/3 → 建议降级")
    }

    func testDemoteNeedsEnoughSamples() {
        var s = LingShuExtensionStateStore()
        s.recordOutcome("p", success: false)
        XCTAssertFalse(s.shouldDemote("p"), "样本不足不降级")
    }
}

// MARK: - P2 动态工具(子进程 JSON 契约)

final class PluginToolRunnerTests: XCTestCase {
    private var scriptURL: URL!

    override func setUpWithError() throws {
        // 一个忽略参数、把 stdin 原样吐到 stdout 的 runner(验证 JSON 入参→结果 的契约)。
        scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("echo-runner-\(UUID().uuidString).sh")
        try "#!/bin/sh\ncat\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: scriptURL) }

    func testRunnerStdinToStdoutRoundTrip() async throws {
        let manifest = LingShuPluginManifest(id: "p", name: "回声插件", version: "1", providedTools: ["echo"], permissions: .init(), source: .user)
        let result = await LingShuPluginToolProvider.runRunner(
            manifest: manifest, toolName: "echo", argumentsJSON: "{\"msg\":\"你好\"}",
            executable: scriptURL.path, baseArguments: [], sandbox: false, timeout: 10)
        XCTAssertTrue(result.contains("你好"), "入参 JSON 应经 stdin→stdout 回来,实得:\(result)")
    }

    func testMakeToolsProducesNamedTool() {
        let manifest = LingShuPluginManifest(id: "p", name: "回声插件", version: "1", providedTools: ["echo"], permissions: .init(), source: .user)
        let tools = LingShuPluginToolProvider.makeTools(
            manifest: manifest, specs: [.init(name: "echo", description: "回声")],
            runnerExecutable: scriptURL.path)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "echo")
        XCTAssertTrue(tools.first?.description.contains("回声插件") ?? false, "描述应标注来源插件")
    }
}

// MARK: - P5 聚合 + 启停 enforcement

@MainActor
final class PluginRegistryTests: XCTestCase {
    private func skill(_ id: String, _ title: String, triggers: [String], perms: LingShuPluginPermissions = .init()) -> LingShuSkillLoader.LoadedSkill {
        .init(profile: .init(id: id, title: title, mission: "m", knowledgeHighlights: [], deliverableTemplate: "t", reviewChecklist: ["c"]),
              triggers: triggers,
              manifest: .init(id: id, name: title, version: "1.0", providedTools: [], permissions: perms, source: .user))
    }

    func testAggregatesSkillsAndMCP() {
        let reg = LingShuExtensionRegistry()
        let exts = reg.extensions(
            skills: [skill("s1", "写作", triggers: ["写"], perms: .init(fileWrite: ["~/Documents/**"]))],
            mcp: [LingShuMCPServerConfig(name: "天气服务", command: "weather-mcp")])
        XCTAssertEqual(exts.count, 2)
        XCTAssertTrue(exts.contains { $0.kind == .skill && $0.name == "写作" })
        XCTAssertTrue(exts.contains { $0.kind == .mcp && $0.name == "天气服务" })
    }

    func testDisabledSkillNotMatched() {
        // P4 enforcement:停用的 skill 不再被专家注册表匹配(落到内置兜底)。
        let registry = LingShuCompositeExpertRegistry(userSkills: [skill("skill-x", "特殊技能", triggers: ["特殊触发词"])])
        XCTAssertEqual(registry.profile(for: "用特殊触发词做事").id, "skill-x", "启用时应命中")
        registry.setDisabledSkillIDs(["skill-x"])
        XCTAssertNotEqual(registry.profile(for: "用特殊触发词做事").id, "skill-x", "停用后不再命中")
    }
}
