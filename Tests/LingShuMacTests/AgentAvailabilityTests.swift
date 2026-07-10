import XCTest
@testable import LingShuMac

/// agent 插件可用性:登录/认证失败信号检测(纯函数)+ 标记不可用后 isAvailableNow 兜住。
final class AgentAvailabilityTests: XCTestCase {

    func testDetectsAuthFailureSignals() {
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("Not logged in · Please run /login"), "未登录")
        XCTAssertNotNil(LingShuAgentPluginStore.outputIndicatesUnavailable("Error: invalid API key provided"))
        XCTAssertNotNil(LingShuAgentPluginStore.outputIndicatesUnavailable("Your credit balance is too low"))
        XCTAssertNotNil(LingShuAgentPluginStore.outputIndicatesUnavailable("请先登录后再使用"))
        XCTAssertNotNil(LingShuAgentPluginStore.outputIndicatesUnavailable("认证失败,token 已过期"))
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("Failed to authenticate. API Error: 401"), "认证失败")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("API Error: 401 {\"error\":{\"message\":\"该令牌已过期\"}}"), "认证失败(401)")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("该令牌已过期"), "令牌过期")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("Your account is on hold"), "账号被暂停")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("API Error: 400 This organization has been disabled."), "组织/账号被禁用")
    }

    func testDetectsCodexQuotaFailureSignals() {
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("You have reached your usage limit"), "额度用尽")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("usage limit reached for this account"), "额度用尽")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("monthly usage limit has been reached"), "额度用尽")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("out of credits"), "额度用尽")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("额度已用尽,请稍后重试"), "额度用尽")
        XCTAssertEqual(LingShuAgentPluginStore.outputIndicatesUnavailable("当前没有额度"), "额度用尽")
    }

    func testUnavailableNoticeNamesPluginInsteadOfGenericWrapup() {
        let plugin = LingShuAgentPlugin(id: "codex", displayName: "Codex", aliases: ["codex"],
                                        executable: "/bin/echo", argsTemplate: ["{{objective}}"])
        let text = "Codex 插件当前不可用:额度用尽。请先恢复后再重试。"
        let notice = LingShuAgentPluginStore.unavailableNotice(from: text, knownPlugins: [plugin])
        XCTAssertEqual(notice?.agentName, "Codex")
        XCTAssertEqual(notice?.message, "Codex 插件当前不可用:额度用尽。请先恢复(如登录/补额度/补凭据)后再重试。")
    }

    func testRunTreatsQuotaOnStdoutAsFailure() async {
        let plugin = LingShuAgentPlugin(
            id: "quota-stdout-\(UUID().uuidString)", displayName: "QuotaStdout",
            executable: "/bin/sh",
            argsTemplate: ["-c", "printf 'You have reached your usage limit'; exit 1"],
            role: .general, timeoutSeconds: 10)
        let result = await LingShuAgentPluginStore.run(plugin, objective: "ignored", workingDirectory: "/tmp")
        guard case .failure(let message) = result else {
            return XCTFail("额度错误落在 stdout 时也应失败,实际:\(result)")
        }
        XCTAssertTrue(message.contains("QuotaStdout 插件当前不可用:额度用尽"), message)
    }

    func testNoFalsePositiveOnNormalOutput() {
        // 代码 agent 正常产出里出现的宽泛词不该误判不可用。
        XCTAssertNil(LingShuAgentPluginStore.outputIndicatesUnavailable("已完成,文件写入 /tmp/a.py,24 passed"))
        XCTAssertNil(LingShuAgentPluginStore.outputIndicatesUnavailable("test_foo: module not found"))
        XCTAssertNil(LingShuAgentPluginStore.outputIndicatesUnavailable("Unauthorized access to /admin route (示例代码注释)"))
        XCTAssertNil(LingShuAgentPluginStore.outputIndicatesUnavailable("示例:服务可能返回 401 Unauthorized,需要业务侧处理"))
    }

    func testMarkedUnavailableOverridesFilePresence() {
        var p = LingShuAgentPlugin(id: "probe", displayName: "Probe", executable: "/bin/echo",
                                   argsTemplate: ["{{objective}}"])
        XCTAssertTrue(p.isAvailableNow, "文件在 + 未标记 → 可用")
        p.available = false
        XCTAssertFalse(p.isAvailableNow, "标记不可用 → 即便文件在也不可用(登录失效兜底)")
        XCTAssertTrue(p.executableExists, "executableExists 仍看文件在(供恢复探活)")
    }
}
