import XCTest
@testable import LingShuMac

/// 适配器发现层:把 agent 自己的"列能力"输出归一成统一能力模型。解析器是纯函数,与子进程解耦,可脱机断言。
final class AgentCapabilityDiscoveryTests: XCTestCase {

    /// 真实 `codex plugin list --json --available` 形态(裁剪):installed + available 两组,各带 pluginId/name/enabled/installed。
    private let codexSample = """
    {
      "installed": [
        {"pluginId":"film-visual-pipeline@personal","name":"film-visual-pipeline","marketplaceName":"personal","installed":true,"enabled":true},
        {"pluginId":"presentations@openai-primary-runtime","name":"presentations","marketplaceName":"openai-primary-runtime","installed":true,"enabled":true}
      ],
      "available": [
        {"pluginId":"picsart@openai-curated","name":"picsart","marketplaceName":"openai-curated","installed":false,"enabled":false}
      ]
    }
    """

    func testParsesCodexPluginListIntoUnifiedCapabilities() {
        let caps = LingShuAgentCapabilityDiscovery.parse(agentID: "codex", format: "codex-plugin-list", output: codexSample)
        XCTAssertEqual(caps.count, 3, "installed(2)+available(1) 都要归一进来")
        let picsart = caps.first { $0.id == "picsart@openai-curated" }
        XCTAssertNotNil(picsart)
        XCTAssertEqual(picsart?.name, "picsart")
        XCTAssertEqual(picsart?.installed, false, "available 组=未安装")
        XCTAssertEqual(picsart?.enabled, false)
        let film = caps.first { $0.id == "film-visual-pipeline@personal" }
        XCTAssertEqual(film?.installed, true)
        XCTAssertEqual(film?.enabled, true)
        XCTAssertEqual(film?.agentID, "codex", "agentID 透传,内核据此知道这能力归谁")
    }

    func testUnknownFormatYieldsEmptyNotCrash() {
        XCTAssertTrue(LingShuAgentCapabilityDiscovery.parse(agentID: "x", format: "no-such-format", output: "whatever").isEmpty)
    }

    func testMalformedOutputYieldsEmpty() {
        XCTAssertTrue(LingShuAgentCapabilityDiscovery.parseCodexPluginList(agentID: "codex", output: "not json").isEmpty)
    }

    func testScansNativeSkillDirAndPrefersInterfaceDisplayName() throws {
        // 原生技能源:扫目录下每个 SKILL.md,frontmatter 出 name/description,agents/*.yaml 的 interface 出友好展示名/短描。
        let tmp = NSTemporaryDirectory() + "lsk-\(UUID().uuidString)"
        let skillDir = tmp + "/imagegen"
        try FileManager.default.createDirectory(atPath: skillDir + "/agents", withIntermediateDirectories: true)
        try "---\nname: \"imagegen\"\ndescription: \"Generate or edit raster images.\"\n---\n# body\n"
            .write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        try "interface:\n  display_name: \"Image Gen\"\n  short_description: \"Generate or edit images for websites, games, and more\"\n"
            .write(toFile: skillDir + "/agents/openai.yaml", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let caps = LingShuAgentCapabilityDiscovery.scanSkillsDir(agentID: "codex", dir: tmp)
        XCTAssertEqual(caps.count, 1)
        let c = caps.first
        XCTAssertEqual(c?.id, "imagegen", "id 取 SKILL.md 的 name")
        XCTAssertEqual(c?.name, "Image Gen", "展示名优先取 interface.display_name")
        XCTAssertEqual(c?.summary, "Generate or edit images for websites, games, and more")
        XCTAssertEqual(c?.enabled, true); XCTAssertEqual(c?.installed, true)
        XCTAssertEqual(c?.agentID, "codex")
    }

    func testRegistrySourceOnlySurfacesInstalledAndRejectsFabricatedDir() throws {
        // **权威注册表防伪**:只认 installed_plugins.json 清单里真装的插件;往清单外的目录塞假 SKILL.md 不该出现。
        let tmp = NSTemporaryDirectory() + "lsreg-\(UUID().uuidString)"
        let fm = FileManager.default
        // 真装插件 A:installPath 下带一个 SKILL.md(插件内技能)。
        let pluginA = tmp + "/cache/alpha"
        try fm.createDirectory(atPath: pluginA + "/skills/writing-rules", withIntermediateDirectories: true)
        try "---\nname: \"writing-rules\"\ndescription: \"Style rules.\"\n---\n"
            .write(toFile: pluginA + "/skills/writing-rules/SKILL.md", atomically: true, encoding: .utf8)
        // 真装插件 B:纯 MCP 插件,installPath 下无 SKILL.md → 插件本身算一个能力。
        let pluginB = tmp + "/cache/beta"
        try fm.createDirectory(atPath: pluginB, withIntermediateDirectories: true)
        // **伪造**:清单外的散目录塞一个假技能——绝不能出现在结果里。
        let fabricated = tmp + "/fabricated/evil"
        try fm.createDirectory(atPath: fabricated, withIntermediateDirectories: true)
        try "---\nname: \"evil-fake\"\ndescription: \"copied from another agent\"\n---\n"
            .write(toFile: fabricated + "/SKILL.md", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: tmp) }

        let registry = """
        {"version":2,"plugins":{
          "writing@official":[{"installPath":"\(pluginA)"}],
          "github@official":[{"installPath":"\(pluginB)"}]
        }}
        """
        let caps = LingShuAgentCapabilityDiscovery.parseClaudeInstalledPlugins(agentID: "claude", data: Data(registry.utf8))
        let ids = Set(caps.map(\.name))
        XCTAssertTrue(ids.contains("writing-rules"), "真装插件内的 SKILL.md 技能应出现")
        XCTAssertTrue(ids.contains("github"), "纯插件(无SKILL.md)插件本身应作为能力")
        XCTAssertFalse(caps.contains { $0.name.contains("evil") }, "清单外伪造的假技能绝不能出现(防伪根治)")
        XCTAssertTrue(caps.allSatisfy { $0.agentID == "claude" && $0.installed })
    }

    func testEnableAndInstallTemplatesFillCapPlaceholder() {
        let spec = AgentCapabilitySpec(
            discover: nil,
            enable: ["-c", "plugins.\"{{cap}}\".enabled=true"],
            install: ["plugin", "add", "{{cap}}"]
        )
        XCTAssertEqual(spec.enableArgs(for: "picsart@openai-curated"),
                       ["-c", "plugins.\"picsart@openai-curated\".enabled=true"])
        XCTAssertEqual(spec.installArgs(for: "picsart@openai-curated"),
                       ["plugin", "add", "picsart@openai-curated"])
    }
}
