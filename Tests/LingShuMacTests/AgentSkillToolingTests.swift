import XCTest
@testable import LingShuMac

/// agent 工具集扩全(缺口3)与本地 skill 接入的回归:外部 MCP 信封解包、按权限级裁剪工具集、
/// apply_skill 调取固化技能并物化自带生成器、命中真 skill 时回合提示。脱网、确定性。
final class AgentSkillToolingTests: XCTestCase {

    @MainActor
    func testStandardPolicyExposesPrimitivesAndApplySkill() {
        let state = LingShuState()
        let names = Set(state.agentBuiltinTools(recordIDProvider: { nil }).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["read_file", "write_file", "list_directory", "fetch_url", "run_command"]))
        XCTAssertTrue(names.isSuperset(of: ["start_long_command", "check_long_command", "cancel_long_command", "list_long_commands"]), "标准策略应暴露宿主托管长命令原语")
        XCTAssertTrue(names.contains("apply_skill"), "标准策略应暴露本地固化技能入口 apply_skill")
        XCTAssertFalse(names.contains("register_agent"), "当前产品态不应暴露外部 agent 插件注册工具")
        XCTAssertFalse(names.contains("run_agent"), "当前产品态不应暴露外部 agent 插件委托工具")
    }

    @MainActor
    func testMinimalVoiceModeRefusesSpawnTask() async {
        // 极简对话模式:纯聊天,spawn_task 直接拒绝,绝不派生子任务(用户要求)。
        let state = LingShuState()
        state.isMinimalVoiceMode = true
        let tool = state.spawnTaskTool(adapter: state.makeAgentModelAdapter())
        let result = await tool.handler("{\"objective\":\"跑个爬虫\"}")
        XCTAssertTrue(result.contains("极简对话模式") && result.contains("不派生子任务"), "极简对话模式应拒绝派生子任务")
        let running = await state.agentOrchestrator.runningCount()
        XCTAssertEqual(running, 0, "极简对话模式下不应真的派生任何子任务")
    }

    @MainActor
    func testReadOnlyPolicyDropsWritesShellAndSkill() {
        let state = LingShuState()
        let names = Set(state.agentBuiltinTools(recordIDProvider: { nil }, executionPolicy: .readOnly).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["read_file", "list_directory", "fetch_url"]))
        XCTAssertFalse(names.contains("write_file"), "只读策略不应暴露写盘原语")
        XCTAssertFalse(names.contains("run_command"), "只读策略不应暴露执行原语")
        XCTAssertFalse(names.contains("start_long_command"), "只读策略不应暴露长命令执行原语")
        XCTAssertFalse(names.contains("apply_skill"), "只读策略不物化生成器,不挂 apply_skill")
    }

    @MainActor
    func testAgentToolsUseCurrentTurnWorkingDirectoryOverrideAtCallTime() async throws {
        let state = LingShuState()
        let defaultDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-tool-default-\(UUID().uuidString)", isDirectory: true)
        let turnDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-tool-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: turnDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: defaultDir)
            try? FileManager.default.removeItem(at: turnDir)
        }
        state.agentWorkingDirectory = defaultDir.path

        let tools = state.agentBuiltinTools(recordIDProvider: { nil })
        guard let writeFile = tools.first(where: { $0.name == "write_file" }) else {
            return XCTFail("write_file 应在标准工具集中")
        }

        state.currentAgentWorkingDirectoryOverride = turnDir.path
        let output = await writeFile.handler(#"{"path":"probe.txt","content":"ok"}"#)

        XCTAssertTrue(output.contains("已写入"), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: turnDir.appendingPathComponent("probe.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultDir.appendingPathComponent("probe.txt").path))
    }

    @MainActor
    func testApplySkillReturnsCuratedPlanAndDesignKBGenerator() async {
        let state = LingShuState()
        let tempDir = NSTemporaryDirectory() + "lingshu-skill-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        state.agentWorkingDirectory = tempDir
        // 测试不依赖用户本机已安装的 skill;先屏蔽用户 skill,确保命中内置策展 PPT 能力。
        if let registry = state.expertProfileRegistry as? LingShuCompositeExpertRegistry {
            let userSkillIDs = Set(registry.allProfiles.map(\.id).filter { $0.hasPrefix("skill-") })
            registry.setDisabledSkillIDs(userSkillIDs)
        }

        let tool = state.applySkillTool()
        let output = await tool.handler("{\"task\":\"帮我做一个自我介绍 PPT\"}")

        // 命中策展 PPT 技能:返回设计要点 + 模板 + DesignKB 高质量生成器路径与跑法(就地跑,不再物化副本)。
        XCTAssertTrue(output.contains("交付物模板") || output.contains("slides.json"), "应返回固化技能的专家提示/模板")
        XCTAssertTrue(output.contains("DesignKB") && output.contains("generator.py"), "应给出 DesignKB 生成器路径")
        XCTAssertTrue(output.contains("python3"), "应给出运行命令")
        XCTAssertTrue(output.contains("find_images") || output.contains("配图"), "应提示用 find_images 取真实配图")
    }

    @MainActor
    func testMatchedSkillHintFiresOnlyForRealSkill() {
        let state = LingShuState()
        if let registry = state.expertProfileRegistry as? LingShuCompositeExpertRegistry {
            let userSkillIDs = Set(registry.allProfiles.map(\.id).filter { $0.hasPrefix("skill-") })
            registry.setDisabledSkillIDs(userSkillIDs)
        }
        XCTAssertNotNil(state.matchedSkillHint(for: "做个自我介绍PPT"), "命中固化技能应广播可发现性提示")
        XCTAssertNil(state.matchedSkillHint(for: "今天天气怎么样"), "无固化技能匹配(内置兜底)不应提示")
    }

    func testExtractFilePathsFindsRunCommandArtifacts() {
        // 验收门据此识别 run_command 产出(不会被 write_file 登记)的真实文件,杜绝"文件不在清单"死循环。
        let reply = "已交付 ✅\n**文件路径**：`/Users/example/app/人工智能发展简史.pptx`（41,965 字节），另有 /Users/example/app/slides.json。"
        let paths = LingShuState.extractFilePaths(from: reply)
        XCTAssertTrue(paths.contains("/Users/example/app/人工智能发展简史.pptx"), "应抽出中文名 .pptx 路径")
        XCTAssertTrue(paths.contains("/Users/example/app/slides.json"), "应抽出 .json 路径")
        XCTAssertTrue(LingShuState.extractFilePaths(from: "我是灵枢，由 Roy Zhao 打造。").isEmpty, "纯对话不应误抽路径")
    }

    @MainActor
    func testUnwrapMCPArgumentsParsesEnvelope() {
        let unwrapped = LingShuState.unwrapMCPArguments(["arguments_json": "{\"path\":\"/tmp/x\",\"n\":3}"])
        XCTAssertEqual(unwrapped["path"] as? String, "/tmp/x")
        XCTAssertEqual(unwrapped["n"] as? Int, 3)
        // 非信封形式(文本协议回退)原样返回。
        let passthrough = LingShuState.unwrapMCPArguments(["query": "灵枢"])
        XCTAssertEqual(passthrough["query"] as? String, "灵枢")
    }
}
