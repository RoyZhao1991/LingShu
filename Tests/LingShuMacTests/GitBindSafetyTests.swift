import XCTest
@testable import LingShuMac

/// 强制绑定 git 的安全护栏(纯逻辑):工程子目录可 init,过宽/敏感目录绝不 init。
final class GitBindSafetyTests: XCTestCase {

    func testProjectSubdirsAllowed() {
        XCTAssertTrue(LingShuState.isSafeToInitGit("/tmp/gateway-demo"))
        XCTAssertTrue(LingShuState.isSafeToInitGit("/Users/x/app/myproject"))
        XCTAssertTrue(LingShuState.isSafeToInitGit(NSHomeDirectory() + "/code/foo"))
    }

    func testBroadAndSensitiveDirsBlocked() {
        XCTAssertFalse(LingShuState.isSafeToInitGit("/"))
        XCTAssertFalse(LingShuState.isSafeToInitGit("/tmp"))
        XCTAssertFalse(LingShuState.isSafeToInitGit("/Users"))
        XCTAssertFalse(LingShuState.isSafeToInitGit("/usr"))
        XCTAssertFalse(LingShuState.isSafeToInitGit(NSHomeDirectory()), "家目录本身不 init")
        XCTAssertFalse(LingShuState.isSafeToInitGit(NSHomeDirectory() + "/Desktop"), "桌面太宽不 init")
        XCTAssertFalse(LingShuState.isSafeToInitGit(NSHomeDirectory() + "/Documents"))
    }
}
