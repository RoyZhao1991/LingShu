import XCTest
@testable import LingShuMac

/// 收尾占位回复识别(纯逻辑)。棘轮:守住"模型最后一步静默 run_command → 把『（无输出，退出码0）』当交付丢给用户"不复发。
final class PlaceholderDeliveryTests: XCTestCase {

    func testDetectsPlaceholderEndings() {
        XCTAssertTrue(LingShuState.isPlaceholderDelivery("✓ run_command：\n（无输出，退出码 0）"))
        XCTAssertTrue(LingShuState.isPlaceholderDelivery("（无输出，退出码 0）"))
        XCTAssertTrue(LingShuState.isPlaceholderDelivery("（已发起工具调用）"))
        XCTAssertTrue(LingShuState.isPlaceholderDelivery("   "))
        XCTAssertTrue(LingShuState.isPlaceholderDelivery(""))
    }

    func testRealDeliveryNotFlagged() {
        XCTAssertFalse(LingShuState.isPlaceholderDelivery("✅ 清分结算系统已构建、编译通过、测试 10/10 全绿、本地跑通。产出在 /Users/x/settlement-system,星巴克应结净额 1368.24 元。"))
        XCTAssertFalse(LingShuState.isPlaceholderDelivery("已完成,服务起在 8080 端口,actuator/health 返回 UP。"))
        // 较长且有实质内容即便提到"退出码"也不算占位
        XCTAssertFalse(LingShuState.isPlaceholderDelivery("程序运行成功,退出码 0,输出了 12 笔交易的清分结果,每个商户的应结净额都已算出并写入结算单文件。"))
    }
}
