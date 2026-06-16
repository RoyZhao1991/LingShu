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
    }
}
