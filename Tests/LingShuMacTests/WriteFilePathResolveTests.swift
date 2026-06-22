import XCTest
@testable import LingShuMac

/// write_file/edit_file 路径解析与围栏(纯逻辑)。棘轮:守住"空参 write_file 给误导的『工作目录内』报错→模型瞎重试卡死"不复发。
final class WriteFilePathResolveTests: XCTestCase {
    private let root = "/Users/example/app"

    func testEmptyPathGivesActionableError() {
        // 空参(模型大内容把工具 JSON 撑爆)→ 必须是"缺少 path"的清晰指引,不是误导的"工作目录内"。
        for p in ["", "   ", "\n"] {
            let r = LingShuLocalToolExecutor.resolveWorkspaceWritePath(p, workingDirectory: root)
            XCTAssertNil(r.resolved, "空路径不该成功")
            XCTAssertTrue(r.error?.contains("缺少 path") ?? false, "应明确提示缺 path: \(r.error ?? "")")
            XCTAssertTrue((r.error?.contains("heredoc") ?? false) || (r.error?.contains("edit_file") ?? false), "应给替代写法指引")
        }
    }

    func testRelativePathResolvedAgainstWorkingDir() {
        // 模型常传相对路径——应以工作目录为基解析,而不是一刀切拒。
        let r = LingShuLocalToolExecutor.resolveWorkspaceWritePath("settlement-platform/tests/t.py", workingDirectory: root)
        XCTAssertEqual(r.resolved, "/Users/example/app/settlement-platform/tests/t.py")
    }

    func testAbsoluteInsideAllowed() {
        let r = LingShuLocalToolExecutor.resolveWorkspaceWritePath("/Users/example/app/proj/main.py", workingDirectory: root)
        XCTAssertEqual(r.resolved, "/Users/example/app/proj/main.py")
    }

    func testOutsideRejected() {
        let r = LingShuLocalToolExecutor.resolveWorkspaceWritePath("/etc/passwd", workingDirectory: root)
        XCTAssertNil(r.resolved, "越界路径不该成功")
        XCTAssertTrue(r.error?.contains("工作目录") ?? false)
    }
}
