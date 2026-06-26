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
    }

    func testNoFalsePositiveOnNormalOutput() {
        // 代码 agent 正常产出里出现的宽泛词不该误判不可用。
        XCTAssertNil(LingShuAgentPluginStore.outputIndicatesUnavailable("已完成,文件写入 /tmp/a.py,24 passed"))
        XCTAssertNil(LingShuAgentPluginStore.outputIndicatesUnavailable("test_foo: module not found"))
        XCTAssertNil(LingShuAgentPluginStore.outputIndicatesUnavailable("Unauthorized access to /admin route (示例代码注释)"))
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
