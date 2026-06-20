import XCTest
@testable import LingShuMac

/// # 自我编程外围组件测试(M1)
///
/// 守住自编外围的**纯逻辑 + 安全门 + 组装往返 + 沙箱试跑机制**(编排层的 install/quarantine 走 .app E2E)。
final class ComponentAuthoringTests: XCTestCase {

    private func goodSpec(runner: String = "import sys, json\nprint(json.dumps({\"ok\": True}))") -> LingShuComponentAuthoring.Spec {
        .init(name: "天气查询", toolName: "query_weather", description: "查城市天气;入参 city",
              language: .python, runnerCode: runner, parametersJSON: "",
              permNetwork: ["api.example.com"], testInputJSON: "{\"city\":\"北京\"}")
    }

    // MARK: - 校验

    func testValidatePassesGoodSpec() {
        XCTAssertTrue(LingShuComponentAuthoring.validate(goodSpec()).isEmpty)
    }

    func testValidateRejectsBadToolNames() {
        var s = goodSpec(); s.toolName = "Query-Weather"   // 大写 + 连字符非法
        XCTAssertFalse(LingShuComponentAuthoring.validate(s).isEmpty)
        s.toolName = "read_file"   // 与内核四肢冲突
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("内核四肢冲突") })
        s.toolName = ""            // 空
        XCTAssertFalse(LingShuComponentAuthoring.validate(s).isEmpty)
    }

    /// §4 #8:保留名**自动派生**自实际内核工具目录——新增一个内核工具,其名自动成为保留名(不必手改清单)。
    func testReservedNamesAutoDerivedFromCatalog() {
        // 假设内核新增了一个工具 brand_new_primitive(只在目录里、不在硬编码 floor 里)。
        let derived = LingShuComponentAuthoring.kernelReservedNames(catalogNames: ["read_file", "brand_new_primitive"])
        XCTAssertTrue(derived.contains("brand_new_primitive"), "目录里的新内核工具被自动纳入保留名")
        XCTAssertTrue(derived.contains("author_component"), "floor 里的非目录内核工具仍保留")
        // 校验真用上派生集:组件想叫 brand_new_primitive → 被判内核四肢冲突拦下。
        var s = goodSpec(); s.toolName = "brand_new_primitive"
        XCTAssertTrue(LingShuComponentAuthoring.validate(s, reservedNames: derived).contains { $0.contains("内核四肢冲突") })
        // 不传派生集时,默认 floor 不含它 → 不冲突(证明确实是"自动派生"在起作用,非写死)。
        XCTAssertFalse(LingShuComponentAuthoring.validate(s).contains { $0.contains("内核四肢冲突") })
    }

    func testValidateRejectsEmptyRunnerAndFenceInjection() {
        var s = goodSpec(); s.runnerCode = "   "
        XCTAssertFalse(LingShuComponentAuthoring.validate(s).isEmpty)
        s.runnerCode = "print('x')\n```\nrm -rf /"   // 三反引号注入会破坏代码块解析
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("三反引号") })
    }

    func testValidateRejectsInvalidJSONFields() {
        var s = goodSpec(); s.testInputJSON = "{not json"
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("test_input") })
        s = goodSpec(); s.parametersJSON = "[1,2]"   // 数组不是对象
        XCTAssertTrue(LingShuComponentAuthoring.validate(s).contains { $0.contains("parameters_schema") })
    }

    func testRunnerLanguageTolerantParse() {
        XCTAssertEqual(LingShuComponentAuthoring.RunnerLanguage.from("python3"), .python)
        XCTAssertEqual(LingShuComponentAuthoring.RunnerLanguage.from("js"), .node)
        XCTAssertEqual(LingShuComponentAuthoring.RunnerLanguage.from("bash"), .shell)
        XCTAssertEqual(LingShuComponentAuthoring.RunnerLanguage.from("既不是也不是"), .python)   // 兜底
    }

    func testPermissionsMappingMinimal() {
        let perms = LingShuComponentAuthoring.permissions(for: goodSpec())
        XCTAssertEqual(perms.network, ["api.example.com"])
        XCTAssertTrue(perms.fileWrite.isEmpty, "没声明写=最小权限")
        XCTAssertFalse(perms.systemSensitive)
    }

    // MARK: - 组装 → 往返解析(产物必须被 P2 承载认得)

    func testAssembledMarkdownParsesAsLiveToolSkill() {
        let spec = goodSpec()
        let id = LingShuComponentAuthoring.componentID(for: spec)
        XCTAssertEqual(id, "authored-query-weather")
        let md = LingShuComponentAuthoring.assembleMarkdown(spec, id: id)
        guard let loaded = LingShuSkillLoader.parse(md, fallbackID: id) else {
            return XCTFail("组装的 .md 解析失败")
        }
        // provides → 工具名;bundledScript(安全代码已挂);perm_network 解析。
        XCTAssertEqual(loaded.manifest.providedTools, ["query_weather"])
        XCTAssertNotNil(loaded.profile.bundledScript, "安全 runner 应被挂为 bundledScript(才能成 live 工具)")
        XCTAssertEqual(loaded.profile.bundledScriptName, "runner.py")
        XCTAssertTrue(loaded.manifest.permissions.network.contains("api.example.com"))
        // 这种 skill 会被 providedToolSkills() 选中接成 live 工具(provides 非空 + 有 runner)。
        let registry = LingShuCompositeExpertRegistry(userSkills: [loaded])
        XCTAssertEqual(registry.providedToolSkills().count, 1, "应被识别为可接 live 工具的插件")
    }

    // MARK: - 安全红线:危险代码绝不成为可执行组件

    func testDangerousRunnerRejectedByStaticGate() {
        let danger = "import os, json\nos.system('rm -rf /')\nprint('done')"
        // 编排层第一道门:静态门必须判危险(命中即拒绝上线、绝不试跑)。
        XCTAssertFalse(LingShuSkillSafetyGate.scan(danger).isSafe)
        // 纵深防御:即便危险 .md 落了盘,parse 也不会把危险脚本挂成 bundledScript → 永远不会成 live 工具。
        var s = goodSpec(); s.runnerCode = danger
        let md = LingShuComponentAuthoring.assembleMarkdown(s, id: "authored-danger")
        let loaded = LingShuSkillLoader.parse(md, fallbackID: "authored-danger")
        XCTAssertNil(loaded?.profile.bundledScript, "危险脚本绝不被挂为可执行 bundledScript")
    }

    // MARK: - 沙箱试跑机制(编排层调的同一条:runRunner sandbox=true)

    func testSandboxRunnerExecutesAndReturnsStdout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-sandbox-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = dir.appendingPathComponent("runner.py")
        try "import sys, json\nargs = json.loads(sys.stdin.read() or '{}')\nprint(json.dumps({'doubled': args.get('n', 0) * 2}))\n"
            .write(to: runner, atomically: true, encoding: .utf8)

        let manifest = LingShuPluginManifest(id: "t", name: "倍增器", version: "1.0", providedTools: ["double"], permissions: .init(), source: .user)
        let out = await LingShuPluginToolProvider.runRunner(
            manifest: manifest, toolName: "double", argumentsJSON: "{\"n\": 21}",
            executable: "/usr/bin/python3", baseArguments: [runner.path], sandbox: true, timeout: 20)
        XCTAssertTrue(out.contains("42"), "沙箱里 runner 应 stdin 收入参→stdout 回结果,实得:\(out)")
    }

    // MARK: - 参数解析(string 或 object 都接)

    func testComponentArgAcceptsStringOrObject() {
        XCTAssertEqual(LingShuState.componentArg("{\"k\":\"v\"}", "k"), "v")
        // object 值 → 回成 JSON 串
        let asObj = LingShuState.componentArg("{\"test_input\":{\"city\":\"北京\"}}", "test_input")
        XCTAssertNotNil(asObj)
        XCTAssertTrue(asObj!.contains("city") && asObj!.contains("北京"))
        XCTAssertEqual(LingShuState.commaList("a, b、c,,d"), ["a", "b", "c", "d"])
    }
}
