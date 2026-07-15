import XCTest
@testable import LingShuMac

final class AgentIntegrationPresetTests: XCTestCase {
    func testCodexComputerUsePresetUsesAuthoritativePluginDiscovery() {
        let preset = LingShuAgentIntegrationPresetCatalog.codexComputerUse
        let plugin = preset.makePlugin(executable: "/tmp/codex")

        XCTAssertEqual(plugin.id, "codex")
        XCTAssertEqual(plugin.argsTemplate.prefix(4), ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check"])
        XCTAssertTrue(plugin.argsTemplate.contains("{{objective}}"))
        XCTAssertEqual(plugin.capabilities?.discover?.args, ["plugin", "list", "--json", "--available"])
        XCTAssertEqual(plugin.capabilities?.discover?.format, "codex-plugin-list")
        XCTAssertFalse(plugin.argsTemplate.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testRequiredComputerUseCapabilityMustBeInstalledAndEnabled() {
        let preset = LingShuAgentIntegrationPresetCatalog.codexComputerUse
        let disabled = LingShuAgentCapability(
            agentID: "codex", id: preset.requiredCapabilityID, name: "computer-use",
            summary: "", category: "openai-bundled", enabled: false, installed: true
        )
        let enabled = LingShuAgentCapability(
            agentID: "codex", id: preset.requiredCapabilityID, name: "computer-use",
            summary: "", category: "openai-bundled", enabled: true, installed: true
        )

        XCTAssertNil(preset.requiredCapability(in: [disabled]))
        XCTAssertEqual(preset.requiredCapability(in: [enabled])?.name, "computer-use")
    }

    func testExecutableResolutionUsesFirstRealCandidateThenPathFallback() {
        let preset = LingShuAgentIntegrationPresetCatalog.codexComputerUse
        let direct = preset.executableCandidates[1]
        let resolved = LingShuAgentIntegrationPresetCatalog.resolveExecutable(
            for: preset,
            isExecutable: { $0 == direct || $0 == "/usr/local/bin/codex" },
            resolveInPath: { $0 == "codex" ? "/usr/local/bin/codex" : nil }
        )
        XCTAssertEqual(resolved, direct)
    }
}
