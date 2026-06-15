import XCTest
@testable import LingShuMac

/// 系统命令分级策略测试(计划 §3 只读免审批 + §1 系统敏感强制审批的纯函数判定)。
final class ShellCommandPolicyTests: XCTestCase {

    func testReadOnlyCommandsPass() {
        let readOnly = [
            "grep -rn foo Sources/",
            "rg --files",
            "find . -name '*.swift'",
            "ls -la",
            "cat README.md",
            "head -20 file.txt",
            "tail -f log",
            "wc -l file",
            "file binary",
            "git status",
            "git log --oneline -10",
            "git diff HEAD~1",
            "grep foo a.txt | head -5",          // 复合:两段都只读
            "ls | sort | uniq"
        ]
        for cmd in readOnly {
            XCTAssertTrue(LingShuShellCommandPolicy.isReadOnly(cmd), "应判为只读: \(cmd)")
        }
    }

    func testWriteOrUnsafeCommandsNotReadOnly() {
        let notReadOnly = [
            "rm file.txt",
            "rm -rf build",
            "mv a b",
            "echo hi > out.txt",            // 重定向写
            "cat a > b",                    // 复合里有写
            "pip install requests",
            "brew install foo",
            "git commit -m x",
            "git push",
            "curl https://x.com",
            "python script.py",             // 非白名单命令
            "grep foo a.txt && rm a.txt",   // 复合:一段是写
            "echo $(rm x)",                 // 命令替换藏写
            "chmod 777 file"
        ]
        for cmd in notReadOnly {
            XCTAssertFalse(LingShuShellCommandPolicy.isReadOnly(cmd), "不应判为只读: \(cmd)")
        }
    }

    func testSystemSensitivePathsDetected() {
        let sensitive = [
            "rm -rf /System/Library/foo",
            "rm /usr/bin/python",
            "mv x /etc/hosts",
            "cp evil /Library/LaunchDaemons/x.plist",
            "chmod 777 /sbin/launchd",
            "rm -rf /",
            "mkfs.hfs /dev/disk2",
            "diskutil erase disk2",
            "csrutil disable",
            "echo x > /etc/passwd"
        ]
        for cmd in sensitive {
            XCTAssertTrue(LingShuShellCommandPolicy.touchesSystemSensitivePath(cmd), "应判为系统敏感: \(cmd)")
        }
    }

    func testNonSensitiveWritesAllowed() {
        let safe = [
            "rm /Users/example/app/tmp.txt",
            "mv out.pptx /Users/example/Desktop/",
            "cp a.txt /usr/local/share/x",      // /usr/local 不在敏感前缀里
            "touch ./build/marker",
            "echo done > result.txt"
        ]
        for cmd in safe {
            XCTAssertFalse(LingShuShellCommandPolicy.touchesSystemSensitivePath(cmd), "不应判为系统敏感: \(cmd)")
        }
    }

    func testReadOnlyNeverMisclassifiesSensitive() {
        // 只读命令即使提到敏感路径也无破坏性(只是读),不算系统敏感。
        XCTAssertFalse(LingShuShellCommandPolicy.touchesSystemSensitivePath("cat /etc/hosts"))
        XCTAssertFalse(LingShuShellCommandPolicy.touchesSystemSensitivePath("ls /System/Library"))
        XCTAssertTrue(LingShuShellCommandPolicy.isReadOnly("cat /etc/hosts"))
    }
}
