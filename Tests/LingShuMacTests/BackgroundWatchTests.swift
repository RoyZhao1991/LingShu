import XCTest
@testable import LingShuMac

/// 后台守候条件判定测试(纯函数)。轮询/续跑涉及 MainActor + Task,不在单测覆盖。
final class BackgroundWatchTests: XCTestCase {

    func testSuccessWhenSubstringRequiresBothSuccessAndMatch() {
        // 公证场景:命令成功 + 输出含 "Accepted" 才算满足。
        XCTAssertTrue(LingShuState.watchConditionMet(commandSucceeded: true, output: "status: Accepted", successWhen: "Accepted"))
        // 还在进行中 → 不满足。
        XCTAssertFalse(LingShuState.watchConditionMet(commandSucceeded: true, output: "status: In Progress", successWhen: "Accepted"))
        // 网络抖动命令失败 → 不满足(继续轮询)。
        XCTAssertFalse(LingShuState.watchConditionMet(commandSucceeded: false, output: "status: Accepted", successWhen: "Accepted"))
    }

    func testEmptySuccessWhenUsesExitCode() {
        // 没给标志 → 以命令成功退出为准(如'等某命令跑通')。
        XCTAssertTrue(LingShuState.watchConditionMet(commandSucceeded: true, output: "", successWhen: ""))
        XCTAssertFalse(LingShuState.watchConditionMet(commandSucceeded: false, output: "anything", successWhen: ""))
    }
}
