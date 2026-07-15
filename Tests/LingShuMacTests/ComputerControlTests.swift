import XCTest
import CoreGraphics
@testable import LingShuMac

/// 计算机直接操作四肢的纯逻辑测试(计划 §9)。事件投递/AX 需真桌面+授权,不在单测覆盖;
/// 这里测可纯函数验证的部分:坐标解析、键码映射、角色/显示名。
final class ComputerControlTests: XCTestCase {

    func testPointParsing() {
        XCTAssertEqual(LingShuState.point(from: ["x": "640", "y": "480"]), CGPoint(x: 640, y: 480))
        XCTAssertEqual(LingShuState.point(from: ["x": "12.5", "y": "0"]), CGPoint(x: 12.5, y: 0))
        XCTAssertNil(LingShuState.point(from: ["x": "640"]), "缺 y 应返回 nil")
        XCTAssertNil(LingShuState.point(from: ["x": "abc", "y": "1"]), "非数值应返回 nil")
    }

    func testKeyCodeMapHasCommonKeys() {
        XCTAssertEqual(LingShuComputerControl.keyCodeMap["return"], 36)
        XCTAssertEqual(LingShuComputerControl.keyCodeMap["c"], 8)
        XCTAssertEqual(LingShuComputerControl.keyCodeMap["escape"], 53)
        XCTAssertEqual(LingShuComputerControl.keyCodeMap["down"], 125)
        XCTAssertNil(LingShuComputerControl.keyCodeMap["不存在的键"])
    }

    func testUIRoleLabel() {
        XCTAssertEqual(LingShuState.uiRoleLabel("AXButton"), "按钮")
        XCTAssertEqual(LingShuState.uiRoleLabel("AXTextField"), "输入框")
        XCTAssertEqual(LingShuState.uiRoleLabel("AXMenuItem"), "菜单项")
        XCTAssertEqual(LingShuState.uiRoleLabel("AXUnknownRole"), "AXUnknownRole", "未知角色原样返回")
    }

    func testComputerToolDisplayNames() {
        XCTAssertEqual(LingShuState.computerToolDisplayName("click"), "点击")
        XCTAssertEqual(LingShuState.computerToolDisplayName("screen_capture"), "截屏看屏")
        XCTAssertEqual(LingShuState.computerToolDisplayName("list_ui_elements"), "列界面元素")
        XCTAssertNil(LingShuState.computerToolDisplayName("write_file"), "非计算机操作工具返回 nil")
    }

    func testShouldSendOriginalScreenshot() {
        let ceiling = LingShuState.screenCaptureOriginalByteCeiling
        // 体积安全的小图(非 Retina / 局部 / 小窗口)直接原图上送,保最大 UI 细节。
        XCTAssertTrue(LingShuState.shouldSendOriginalScreenshot(pngByteCount: 300_000))
        XCTAssertTrue(LingShuState.shouldSendOriginalScreenshot(pngByteCount: ceiling - 1))
        XCTAssertTrue(LingShuState.shouldSendOriginalScreenshot(pngByteCount: ceiling), "等于上限算安全")
        // 全屏 Retina ~4MB 远超上限 → 不发原图,改走缩图(避开上游连续 3 次失败→500)。
        XCTAssertFalse(LingShuState.shouldSendOriginalScreenshot(pngByteCount: ceiling + 1))
        XCTAssertFalse(LingShuState.shouldSendOriginalScreenshot(pngByteCount: 4_000_000))
        // 读不到(0 字节)不发原图。
        XCTAssertFalse(LingShuState.shouldSendOriginalScreenshot(pngByteCount: 0))
    }

    func testToolDisplayNameRoutesComputerTools() {
        // toolDisplayName 应能回退到计算机操作工具名(供进展气泡)。
        XCTAssertEqual(LingShuState.toolDisplayName("type_text"), "键入文本")
        XCTAssertEqual(LingShuState.toolDisplayName("scroll"), "滚动")
        XCTAssertEqual(LingShuState.toolDisplayName("computer_get_state"), "读取应用状态")
        XCTAssertEqual(LingShuState.toolDisplayName("computer_click_element"), "点击界面元素")
    }

    func testNativeComputerUseMatchesAppWithoutModelSpecificRules() {
        let apps = [
            LingShuComputerAppSummary(pid: 10, name: "Safari", bundleIdentifier: "com.apple.Safari", executablePath: "/Applications/Safari.app", isActive: false),
            LingShuComputerAppSummary(pid: 11, name: "备忘录", bundleIdentifier: "com.apple.Notes", executablePath: "/System/Applications/Notes.app", isActive: true),
        ]
        XCTAssertEqual(LingShuNativeComputerUsePolicy.matchApp(query: "frontmost", candidates: apps)?.pid, 11)
        XCTAssertEqual(LingShuNativeComputerUsePolicy.matchApp(query: "com.apple.Safari", candidates: apps)?.pid, 10)
        XCTAssertEqual(LingShuNativeComputerUsePolicy.matchApp(query: "safari", candidates: apps)?.pid, 10)
        XCTAssertEqual(LingShuNativeComputerUsePolicy.matchApp(query: "11", candidates: apps)?.pid, 11)
        XCTAssertNil(LingShuNativeComputerUsePolicy.matchApp(query: "不存在", candidates: apps))
    }

    func testNativeComputerUseDiffReportsSemanticChange() {
        let before = nativeNode(index: 1, role: "AXButton", title: "保存", value: "")
        let unchanged = LingShuNativeComputerUsePolicy.diff(
            previousSnapshotID: "cu-old",
            previous: [before],
            current: [before]
        )
        XCTAssertFalse(unchanged.changed)

        let after = nativeNode(index: 1, role: "AXButton", title: "已保存", value: "")
        let changed = LingShuNativeComputerUsePolicy.diff(
            previousSnapshotID: "cu-old",
            previous: [before],
            current: [after]
        )
        XCTAssertTrue(changed.changed)
        XCTAssertTrue(changed.added.contains { $0.contains("已保存") })
        XCTAssertTrue(changed.removed.contains { $0.contains("保存") })
    }

    func testNativeComputerUseRequiresConfirmationForIrreversibleTargets() {
        XCTAssertTrue(LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: "确认付款", action: "AXPress"))
        XCTAssertTrue(LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: "Delete permanently", action: "click"))
        XCTAssertTrue(LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: "发送消息", action: "return"))
        XCTAssertFalse(LingShuNativeComputerUsePolicy.requiresExplicitConfirmation(label: "打开设置", action: "AXPress"))
    }

    func testNativeComputerUseRedactsSensitiveInputValues() {
        XCTAssertEqual(
            LingShuNativeComputerUsePolicy.redactedValue(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                title: "密码",
                help: "",
                identifier: "password",
                value: "never-send-this"
            ),
            "（敏感内容已隐藏）"
        )
        XCTAssertEqual(
            LingShuNativeComputerUsePolicy.redactedValue(
                role: "AXTextField",
                subrole: "",
                title: "DeepSeek API Token",
                help: "",
                identifier: "brain-token",
                value: "sk-secret"
            ),
            "（敏感内容已隐藏）"
        )
        XCTAssertEqual(
            LingShuNativeComputerUsePolicy.redactedValue(
                role: "AXTextField",
                subrole: "",
                title: "搜索",
                help: "",
                identifier: "search",
                value: "灵枢"
            ),
            "灵枢"
        )
    }

    func testNativeComputerUseToolsHaveCorrectEffects() {
        XCTAssertEqual(LingShuToolMetadata.inferred(name: "computer_get_state", parametersJSON: "{}").effect, .readOnly)
        XCTAssertEqual(LingShuToolMetadata.inferred(name: "computer_click_element", parametersJSON: "{}").effect, .control)
        XCTAssertEqual(LingShuToolMetadata.inferred(name: "click", parametersJSON: "{}").parallelPolicy, .serial)
    }

    private func nativeNode(index: Int, role: String, title: String, value: String) -> LingShuComputerStateNode {
        LingShuComputerStateNode(
            index: index,
            role: role,
            subrole: "",
            title: title,
            value: value,
            help: "",
            identifier: "",
            enabled: true,
            focused: false,
            valueSettable: false,
            frame: CGRect(x: 10, y: 20, width: 80, height: 30),
            actions: ["AXPress"]
        )
    }
}
