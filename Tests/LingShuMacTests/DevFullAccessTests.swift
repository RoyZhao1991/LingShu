import XCTest
@testable import LingShuMac

/// 开发阶段全权(2026-06-21,用户拍板):系统授权门在开发期直接放行,不每次弹框;发布后人工授权。
/// 例外:未审第三方 skill 脚本(供应链红线)仍拦。
@MainActor
final class DevFullAccessTests: XCTestCase {

    func testDevFullAccessAutoGrantsShellWithoutPrompt() async {
        let state = LingShuState()
        state.developmentPhaseFullAccess = true
        // 普通命令:直接 .allowAlways,不挂起弹窗。
        let d = await state.requestShellApproval(command: "python3 app.py", workingDirectory: "/tmp", taskRecordID: nil)
        XCTAssertEqual(d, .allowAlways, "开发全权下普通命令应直接放行")
        XCTAssertNil(state.pendingShellApproval, "不应弹审批窗")
    }

    func testDevFullAccessGrantsSystemSensitiveNoPrompt() async {
        let state = LingShuState()
        state.developmentPhaseFullAccess = true
        // 系统级敏感(forceConfirm)在开发全权下也放行(留审计日志),不弹窗。
        let d = await state.requestShellApproval(command: "rm -rf /etc/whatever", workingDirectory: "/tmp", taskRecordID: nil, forceConfirm: true)
        XCTAssertEqual(d, .allowAlways)
        XCTAssertNil(state.pendingShellApproval)
    }

    func testReleaseModeDoesNotPreauthorize() {
        // 关掉开发全权 + 人工授权 + 未会话授权 → 不预授权(发布后回到人工授权门;交互环境会弹窗,
        // 故这里只断言"不预授权",不真正 await requestShellApproval 以免测试挂在等弹窗)。
        let state = LingShuState()
        state.developmentPhaseFullAccess = false
        state.requireHumanApproval = true
        state.sessionShellAlwaysAllowed = false
        XCTAssertFalse(state.shellPreauthorized, "关掉开发全权后 shell 不应被预授权(恢复人工授权门)")
    }

    func testToggleAndPersistence() {
        let state = LingShuState()
        state.setDevelopmentPhaseFullAccess(false)
        XCTAssertFalse(state.developmentPhaseFullAccess)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "lingshu.devFullAccess") as? Bool, false)
        state.setDevelopmentPhaseFullAccess(true)
        XCTAssertTrue(state.developmentPhaseFullAccess)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "lingshu.devFullAccess") as? Bool, true)
        UserDefaults.standard.removeObject(forKey: "lingshu.devFullAccess")   // 清理,不污染其它用例
    }

    func testShellPreauthorizedWhenDevFullAccess() {
        let state = LingShuState()
        state.developmentPhaseFullAccess = true
        state.requireHumanApproval = true
        state.sessionShellAlwaysAllowed = false
        XCTAssertTrue(state.shellPreauthorized, "开发全权应视作 shell 已预授权(后台守候等路径不被卡)")
    }

    func testDevFullAccessAutoGrantsManagedModeWithoutPrompt() async {
        let state = LingShuState()
        state.developmentPhaseFullAccess = true

        let approved = await state.requestManagedMode(reason: "全屏演示当前预览文档")

        XCTAssertTrue(approved, "开发全权下可逆的托管演示入口应直接审计放行,不能弹同步确认卡住 MCP/自主执行")
        XCTAssertTrue(state.managedModePreauthorized)
        XCTAssertTrue(state.executionTrace.contains { $0.title == "托管模式已预授权" })
        XCTAssertFalse(state.isStandingPersonOnDuty, "requestManagedMode 只裁决权限,不应自行切换上岗状态")
    }
}
