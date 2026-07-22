import XCTest
@testable import LingShuMac

/// # 内核 ABI 契约测试(M0 固核)
///
/// 守住五大内核协议的**形状**:任一协议增删/改字段、改方法签名、改名 → 本文件**编译红**;
/// 内核版本钉死 → 改了协议却没升版本/没更文档 → **断言红**。让外围组件随便长,内核契约不被改坏。
///
/// 钉死方式:
/// - 每个协议写一个"穿透函数"(`_uses…`),引用其**全部冻结面符号**——删/改任一符号即编译失败。
/// - 版本/契约清单/文档一致性用运行时断言。
final class KernelABIContractTests: XCTestCase {

    // MARK: - 版本 + 契约清单单一真相源

    func testKernelVersionPinned() {
        // 改了任一内核协议形状,必须同步升这个版本(并更新 Docs/灵枢内核ABI.md)。改这行=有意识的内核契约变更。
        XCTAssertEqual(LingShuKernelABI.version, "1.0.0", "内核 ABI 版本变了:确认是有意的契约改动,并更新文档/契约测试")
        XCTAssertTrue(LingShuKernelABI.selfCheck(), "内核 ABI 清单自洽校验失败(契约数/重名/空冻结面)")
    }

    func testWindowsRuntimeUsesTheSameKernelContract() throws {
        let contractURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runtime/LingShuCore/resources/kernel-contract.json")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as? [String: Any]
        )
        XCTAssertEqual(object["abiVersion"] as? String, LingShuKernelABI.version)
        let portableContracts = try XCTUnwrap(object["contracts"] as? [[String: Any]])
        XCTAssertEqual(
            portableContracts.compactMap { $0["symbol"] as? String },
            LingShuKernelABI.contracts.map(\.symbol),
            "Windows 与 macOS 必须由同一份五协议内核 ABI 驱动"
        )
        for (portable, native) in zip(portableContracts, LingShuKernelABI.contracts) {
            XCTAssertEqual(portable["frozenSurface"] as? [String], native.frozenSurface)
        }
        XCTAssertEqual(object["goalSpecFields"] as? [String], [
            "objective", "kind", "output_mode", "reference_scope",
            "reference_evidence", "reference_explicit", "reference_confidence",
            "constraints", "boundaries", "risks", "success_criteria", "open_questions"
        ])
        XCTAssertEqual(object["providerProtocols"] as? [String], [
            "openai_responses", "openai_chat_completions", "anthropic_messages"
        ])
        let platforms = try XCTUnwrap(object["platformCapabilities"] as? [String: Any])
        let windows = try XCTUnwrap(platforms["windows"] as? [String: Any])
        XCTAssertEqual(windows["computerControl"] as? Bool, false)
        XCTAssertEqual(windows["internalPreview"] as? Bool, true)
    }

    func testMacAndWindowsExecuteTheSameRustRuntimeKernelImplementation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let windowsCargo = try String(
            contentsOf: repository.appendingPathComponent("WindowsApp/src-tauri/Cargo.toml"),
            encoding: .utf8
        )
        let windowsHost = try String(
            contentsOf: repository.appendingPathComponent("WindowsApp/src-tauri/src/lib.rs"),
            encoding: .utf8
        )
        let macHostCargo = try String(
            contentsOf: repository.appendingPathComponent(
                "Runtime/Grok/crates/codegen/lingshu-grok-runtime/Cargo.toml"
            ),
            encoding: .utf8
        )
        let macHost = try String(
            contentsOf: repository.appendingPathComponent(
                "Runtime/Grok/crates/codegen/lingshu-grok-runtime/src/kernel_host.rs"
            ),
            encoding: .utf8
        )
        let macBridge = try String(
            contentsOf: repository.appendingPathComponent("Sources/Runtime/LingShuSharedKernelRuntime.swift"),
            encoding: .utf8
        )
        let macMainState = try String(
            contentsOf: repository.appendingPathComponent("Sources/State/LingShuState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(windowsCargo.contains("lingshu-runtime-core = { path = \"../../Runtime/LingShuCore\" }"))
        XCTAssertTrue(windowsHost.contains("RuntimeKernel::new(store, \"windows\")"))
        XCTAssertTrue(macHostCargo.contains("lingshu-runtime-core = { path = \"../../../../LingShuCore\" }"))
        XCTAssertTrue(macHost.contains("RuntimeKernel::new(store, config.platform)"))
        XCTAssertTrue(macBridge.contains("lingshu_kernel_runtime_start"))
        XCTAssertTrue(macBridge.contains("lingshu_kernel_runtime_send"))
        XCTAssertTrue(macMainState.contains("submitSharedKernelTurn("))
        XCTAssertTrue(macMainState.contains("if LingShuRuntimeEnvironment.usesSharedRuntimeKernel"))
    }

    func testFiveKernelContractsEnumerated() {
        let symbols = LingShuKernelABI.contracts.map(\.symbol)
        XCTAssertEqual(symbols, [
            "LingShuAgentSessioning",
            "LingShuAgentTool",
            "LingShuPluginToolProvider",
            "LingShuExternalSensorySource",
            "LingShuPluginManifest"
        ], "五大内核协议清单变了:内核平台契约改动需评审 + 升版本")
    }

    /// 文档↔代码一致:每个内核协议符号必须在《灵枢内核ABI》文档里出现(防文档漂移)。
    func testDocMentionsEveryKernelContract() throws {
        let docURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Docs/灵枢内核ABI.md")
        let doc = try String(contentsOf: docURL, encoding: .utf8)
        XCTAssertTrue(doc.contains("内核 ABI 版本:\(LingShuKernelABI.version)"), "文档需标注与代码一致的内核 ABI 版本")
        for contract in LingShuKernelABI.contracts {
            XCTAssertTrue(doc.contains(contract.symbol), "文档缺内核协议「\(contract.symbol)」的说明")
        }
    }

    // MARK: - ① 核心循环 LingShuAgentSessioning

    /// 编译期穿透:引用 `LingShuAgentSessioning` 的全部冻结面成员。删/改任一即编译失败。
    private func _usesSessioning(_ s: any LingShuAgentSessioning) async {
        await s.setTextDeltaSink(nil)
        _ = await s.isBlocked
        _ = await s.turnsUsed
        _ = await s.toolInvocations
        _ = await s.messages
        _ = await s.injectCorrection("x")
        await s.injectBriefing("x")
        _ = await s.send("x")
        _ = await s.resume("x")
        _ = await s.continueLoop()
    }

    /// 两份实现都必须 conform(经典 + 嵌套)——编译期保证工厂可返回任一。
    private func _classicConforms(_ s: LingShuAgentSession) -> any LingShuAgentSessioning { s }
    private func _nestedConforms(_ s: LingShuNestedAgentSession) -> any LingShuAgentSessioning { s }

    func testCoreLoopProtocolDrivesScriptedSession() async {
        let session = LingShuAgentSession(
            id: "abi", system: "s", tools: [],
            model: LingShuScriptedAgentModel([.text("done")]), maxTurns: 2)
        let upcast: any LingShuAgentSessioning = session   // 经典实现 conform
        let result = await upcast.send("hi")
        XCTAssertEqual(result, .completed(text: "done"))
        let blocked = await upcast.isBlocked
        XCTAssertFalse(blocked)
    }

    func testRunResultCarriesAllContractCases() {
        // 收尾/卡住/撞顶/基础设施中断四态都在契约里,逐个 switch 钉死(新增/删 case 即编译红)。
        let cases: [LingShuAgentRunResult] = [
            .completed(text: "c"), .blocked(question: "q"),
            .maxTurnsReached(lastText: "m"), .interrupted(reason: "i")
        ]
        for c in cases {
            switch c {
            case .completed(let t): XCTAssertEqual(t, "c")
            case .blocked(let q): XCTAssertEqual(q, "q")
            case .maxTurnsReached(let m): XCTAssertEqual(m, "m")
            case .interrupted(let r): XCTAssertEqual(r, "i")
            }
        }
    }

    // MARK: - ② 工具 ABI LingShuAgentTool

    func testToolABIShapeAndHandler() async {
        let tool = LingShuAgentTool(
            name: "abi_echo",
            description: "回声",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { args in "echo:\(args)" }
        // 冻结面四字段全引用。
        XCTAssertEqual(tool.name, "abi_echo")
        XCTAssertEqual(tool.description, "回声")
        XCTAssertTrue(tool.parametersJSON.contains("object"))
        let out = await tool.handler("{\"x\":1}")
        XCTAssertEqual(out, "echo:{\"x\":1}")
    }

    func testToolABIDefaultSchema() {
        // 默认 parametersJSON 是合法空对象 schema(外围最简工具可省 schema)。
        let tool = LingShuAgentTool(name: "n", description: "d") { _ in "" }
        XCTAssertTrue(tool.parametersJSON.contains("\"type\":\"object\""))
    }

    // MARK: - ③ 外围 runner 契约 LingShuPluginToolProvider

    func testRunnerContractStdinToStdout() async throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("abi-runner-\(UUID().uuidString).sh")
        try "#!/bin/sh\ncat\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let manifest = LingShuPluginManifest(id: "p", name: "回声", version: "1", providedTools: ["echo"], permissions: .init(), source: .user)
        // ToolSpec / makeTools 冻结面。
        let specs = [LingShuPluginToolProvider.ToolSpec(name: "echo", description: "回声")]
        let tools = LingShuPluginToolProvider.makeTools(manifest: manifest, specs: specs, runnerExecutable: scriptURL.path, sandbox: false)
        XCTAssertEqual(tools.first?.name, "echo")
        // runRunner 冻结面:入参 JSON → stdin → stdout。
        let out = await LingShuPluginToolProvider.runRunner(
            manifest: manifest, toolName: "echo", argumentsJSON: "{\"v\":\"灵枢\"}",
            executable: scriptURL.path, baseArguments: [], sandbox: false, timeout: 10)
        XCTAssertTrue(out.contains("灵枢"), "runner 子进程契约:stdin 入参应经 stdout 回来,实得:\(out)")
    }

    // MARK: - ④ 感知输入 LingShuExternalSensorySource + Reading

    /// 一个最小 mock 感知源:conform 协议 + 吐一条归一读数。删/改协议形状即编译红。
    private final class MockSensorySource: LingShuExternalSensorySource {
        let descriptor = LingShuExternalSensoryDescriptor(
            id: "abi-mock", displayName: "ABI 模拟源", englishName: "ABI Mock",
            channel: .smartHome, requiresPairing: false, summary: "契约测试用", englishSummary: "for contract test")
        func activate() -> AsyncStream<LingShuExternalSensorySignal> {
            AsyncStream { continuation in
                continuation.yield(.status(.streaming))
                continuation.yield(.reading(LingShuExternalSensoryReading(
                    channel: .smartHome, sourceID: "abi-mock", headline: "测试读数", salience: 2)))
                continuation.finish()
            }
        }
        func deactivate() {}
    }

    func testSensorySourceContractEmitsReading() async {
        let source: any LingShuExternalSensorySource = MockSensorySource()
        XCTAssertEqual(source.descriptor.id, "abi-mock")   // descriptor 冻结面
        var sawReading = false
        for await signal in source.activate() {            // activate 冻结面
            // 信号枚举四 case 钉死(状态/读数/通知/致命)。
            switch signal {
            case .status(let st): XCTAssertTrue(st.isActive)
            case .reading(let r):
                sawReading = true
                XCTAssertEqual(r.channel, .smartHome)
                XCTAssertEqual(r.headline, "测试读数")
                XCTAssertEqual(r.salience, 2)
            case .notification, .fatal: break
            }
        }
        source.deactivate()   // deactivate 冻结面
        XCTAssertTrue(sawReading, "感知源契约:activate 应产出归一读数")
    }

    // MARK: - ⑤ 插件清单/权限 LingShuPluginManifest

    func testManifestContractParsesPermissions() {
        let manifest = LingShuPluginManifest.from(frontmatter: [
            "id": "demo", "title": "演示外围", "version": "2.0",
            "provides": "do_x, do_y", "perm_read": "~/Documents/**", "perm_network": "api.example.com", "perm_shell": "true"
        ], source: .user)
        // 全字段冻结面。
        XCTAssertEqual(manifest.id, "demo")
        XCTAssertEqual(manifest.name, "演示外围")
        XCTAssertEqual(manifest.version, "2.0")
        XCTAssertEqual(manifest.providedTools, ["do_x", "do_y"])
        XCTAssertTrue(manifest.permissions.network.contains("api.example.com"))
        XCTAssertTrue(manifest.permissions.shell)
        XCTAssertEqual(manifest.source, .user)
        XCTAssertTrue(manifest.permissionSummary.contains("联网"))
    }
}
