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
        XCTAssertTrue(names.contains("apply_skill"), "标准策略应暴露本地固化技能入口 apply_skill")
    }

    @MainActor
    func testReadOnlyPolicyDropsWritesShellAndSkill() {
        let state = LingShuState()
        let names = Set(state.agentBuiltinTools(recordIDProvider: { nil }, executionPolicy: .readOnly).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["read_file", "list_directory", "fetch_url"]))
        XCTAssertFalse(names.contains("write_file"), "只读策略不应暴露写盘原语")
        XCTAssertFalse(names.contains("run_command"), "只读策略不应暴露执行原语")
        XCTAssertFalse(names.contains("apply_skill"), "只读策略不物化生成器,不挂 apply_skill")
    }

    @MainActor
    func testApplySkillReturnsCuratedPlanAndMaterializesGenerator() async {
        let state = LingShuState()
        let tempDir = NSTemporaryDirectory() + "lingshu-skill-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        state.codexWorkingDirectory = tempDir

        let tool = state.applySkillTool()
        let output = await tool.handler("{\"task\":\"帮我做一个自我介绍 PPT\"}")

        // 命中策展 PPT 技能:返回设计要点 + 自带生成器路径。
        XCTAssertTrue(output.contains("交付物模板") || output.contains("专家档案"), "应返回固化技能的专家提示")
        XCTAssertTrue(output.contains("生成器"), "命中含 generator 的技能应给出脚本路径")
        // 生成器真物化到工作目录(不是只口头说就绪)。
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/generator.py"), "自带生成器应真写入工作目录")
    }

    @MainActor
    func testMatchedSkillHintFiresOnlyForRealSkill() {
        let state = LingShuState()
        XCTAssertNotNil(state.matchedSkillHint(for: "做个自我介绍PPT"), "命中固化技能应广播可发现性提示")
        XCTAssertNil(state.matchedSkillHint(for: "今天天气怎么样"), "无固化技能匹配(内置兜底)不应提示")
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
