import XCTest
@testable import LingShuMac

final class ToolCallParserTests: XCTestCase {
    func testParsesToolLinesAndStripsThem() {
        let reply = """
        我先看一下目录结构。
        【工具】{"tool":"list_directory","arguments":{"path":"/tmp"}}
        【工具】{"tool":"read_file","arguments":{"path":"/tmp/a.txt"}}
        然后继续。
        """
        let requests = LingShuToolCallParser.parse(reply)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].tool, "list_directory")
        XCTAssertEqual(requests[1].arguments["path"], "/tmp/a.txt")

        let stripped = LingShuToolCallParser.strippingToolLines(reply)
        XCTAssertFalse(stripped.contains("【工具】"))
        XCTAssertTrue(stripped.contains("我先看一下目录结构。"))
        XCTAssertTrue(stripped.contains("然后继续。"))
    }

    func testIgnoresMalformedToolLines() {
        XCTAssertTrue(LingShuToolCallParser.parse("【工具】不是JSON").isEmpty)
        XCTAssertTrue(LingShuToolCallParser.parse("正文里提到【工具】但不在行首的不算？其实在行首才算").count <= 1)
    }
}

final class LocalToolExecutorTests: XCTestCase {
    private let executor = LingShuLocalToolExecutor()
    private var workDir: String!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-tools-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: workDir)
        super.tearDown()
    }

    func testWriteFileConfinedToWorkingDirectory() async {
        let inside = await executor.execute(
            .init(tool: "write_file", arguments: ["path": "\(workDir!)/out/note.md", "content": "你好"]),
            workingDirectory: workDir, allowShell: false
        )
        XCTAssertTrue(inside.success)
        XCTAssertEqual(try? String(contentsOfFile: "\(workDir!)/out/note.md", encoding: .utf8), "你好")

        let outside = await executor.execute(
            .init(tool: "write_file", arguments: ["path": "/tmp/lingshu-escape.txt", "content": "x"]),
            workingDirectory: workDir, allowShell: false
        )
        XCTAssertFalse(outside.success, "工作目录之外的写入必须拒绝")
    }

    func testReadFileLineRangeAndLineNumbers() async {
        let path = "\(workDir!)/big.txt"
        let content = (1...300).map { "line\($0)" }.joined(separator: "\n")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        // 默认读:带行号、能看到首行(不再 8KB 截断)。
        let head = await executor.execute(.init(tool: "read_file", arguments: ["path": path]), workingDirectory: workDir, allowShell: false)
        XCTAssertTrue(head.success)
        XCTAssertTrue(head.output.contains("1\tline1"), "应带 cat -n 行号")
        XCTAssertTrue(head.output.contains("300\tline300"), "300 行应能整文件读到(无 8KB 截断)")
        // 行范围读:offset/limit。
        let mid = await executor.execute(.init(tool: "read_file", arguments: ["path": path, "offset": "100", "limit": "3"]), workingDirectory: workDir, allowShell: false)
        XCTAssertTrue(mid.output.contains("100\tline100"))
        XCTAssertTrue(mid.output.contains("102\tline102"))
        XCTAssertFalse(mid.output.contains("\tline104"), "limit 之外不应返回")
    }

    func testEditFileUniqueReplace() async {
        let path = "\(workDir!)/code.swift"
        try? "let a = 1\nlet b = 2\nlet c = 3\n".write(toFile: path, atomically: true, encoding: .utf8)
        // 唯一匹配替换成功。
        let ok = await executor.execute(.init(tool: "edit_file", arguments: ["path": path, "old_string": "let b = 2", "new_string": "let b = 20"]), workingDirectory: workDir, allowShell: false)
        XCTAssertTrue(ok.success)
        XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), "let a = 1\nlet b = 20\nlet c = 3\n")
        // 找不到 → 拒绝。
        let miss = await executor.execute(.init(tool: "edit_file", arguments: ["path": path, "old_string": "不存在的串", "new_string": "x"]), workingDirectory: workDir, allowShell: false)
        XCTAssertFalse(miss.success)
        // 不唯一 → 拒绝(保护性,逼带上下文)。
        try? "x\nx\n".write(toFile: path, atomically: true, encoding: .utf8)
        let dup = await executor.execute(.init(tool: "edit_file", arguments: ["path": path, "old_string": "x", "new_string": "y"]), workingDirectory: workDir, allowShell: false)
        XCTAssertFalse(dup.success)
        XCTAssertTrue(dup.output.contains("不唯一"))
        // 工作目录外 → 拒绝。
        let outside = await executor.execute(.init(tool: "edit_file", arguments: ["path": "/tmp/lingshu-edit-escape.swift", "old_string": "a", "new_string": "b"]), workingDirectory: workDir, allowShell: false)
        XCTAssertFalse(outside.success)
    }

    func testReadDeniesSensitiveLocations() async {
        let denied = await executor.execute(
            .init(tool: "read_file", arguments: ["path": "\(NSHomeDirectory())/.ssh/id_rsa"]),
            workingDirectory: workDir, allowShell: false
        )
        XCTAssertFalse(denied.success)
        XCTAssertTrue(denied.output.contains("敏感"))
    }

    func testRunCommandRespectsApprovalPolicy() async {
        let refused = await executor.execute(
            .init(tool: "run_command", arguments: ["command": "echo hi"]),
            workingDirectory: workDir, allowShell: false
        )
        XCTAssertFalse(refused.success, "未获授权（allowShell=false）时命令必须拒绝")
        XCTAssertTrue(refused.output.contains("拒绝"))

        let allowed = await executor.execute(
            .init(tool: "run_command", arguments: ["command": "echo lingshu-ok"]),
            workingDirectory: workDir, allowShell: true
        )
        XCTAssertTrue(allowed.success)
        XCTAssertTrue(allowed.output.contains("lingshu-ok"))
    }

    func testRunCommandDoesNotHangOnStdinReadingCommand() async {
        // cat 无参会读 stdin；nullDevice 立即给 EOF，应快速退出而不是卡到超时。
        let start = Date()
        let result = await executor.runCommand("cat", workingDirectory: workDir, allowShell: true, timeout: 8)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "交互式读 stdin 的命令不应挂起")
        XCTAssertTrue(result.success)
    }

    func testRunCommandTimesOutAndForceTerminates() async {
        let start = Date()
        let result = await executor.runCommand("sleep 30", workingDirectory: workDir, allowShell: true, timeout: 2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 6, "应在超时附近强制收口，不等 sleep 30 跑完")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("超时"))
    }

    func testRunCommandDoesNotHangWhenChildSpawnsLingeringGrandchild() async {
        // 命令起一个持有 stdout fd 的后台孙进程后立刻退出——
        // 旧实现的 readDataToEndOfFile 会因孙进程不关 fd 而永久阻塞。
        let start = Date()
        let result = await executor.runCommand("(sleep 20 &) ; echo done", workingDirectory: workDir, allowShell: true, timeout: 8)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "孙进程僵死不应让工具调用挂起")
        XCTAssertTrue(result.output.contains("done"))
    }

    func testRunCommandCapturesOutput() async {
        let result = await executor.runCommand("echo hello-lingshu", workingDirectory: workDir, allowShell: true, timeout: 8)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("hello-lingshu"))
    }

    func testRunCommandBlocksDangerousCommands() async {
        let blocked = await executor.execute(
            .init(tool: "run_command", arguments: ["command": "sudo rm -rf /"]),
            workingDirectory: workDir, allowShell: true
        )
        XCTAssertFalse(blocked.success)
        XCTAssertTrue(blocked.output.contains("黑名单"))
    }

    func testListDirectoryWorks() async {
        _ = await executor.execute(
            .init(tool: "write_file", arguments: ["path": "\(workDir!)/a.txt", "content": "1"]),
            workingDirectory: workDir, allowShell: false
        )
        let listing = await executor.execute(
            .init(tool: "list_directory", arguments: ["path": workDir]),
            workingDirectory: workDir, allowShell: false
        )
        XCTAssertTrue(listing.success)
        XCTAssertTrue(listing.output.contains("a.txt"))
    }
}

@MainActor
final class ScheduledTriggerTests: XCTestCase {
    private func makeService() -> LingShuScheduledTriggerService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-triggers-\(UUID().uuidString)", isDirectory: true)
        return LingShuScheduledTriggerService(directory: dir)
    }

    private func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 10, of: Date())!
    }

    func testDailyTriggerFiresAtScheduledMinuteOnce() {
        let service = makeService()
        service.add(title: "喝水", prompt: "提醒我喝水", hour: 9, minute: 30, repeatsDaily: true)

        XCTAssertTrue(service.fireDueTriggers(now: date(hour: 9, minute: 29)).isEmpty)
        let fired = service.fireDueTriggers(now: date(hour: 9, minute: 30))
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.prompt, "提醒我喝水")
        // 同一分钟内不重复触发
        XCTAssertTrue(service.fireDueTriggers(now: date(hour: 9, minute: 30)).isEmpty)
        // 每日任务保持启用
        XCTAssertTrue(service.triggers.first!.enabled)
    }

    func testOneShotTriggerDisablesAfterFiring() {
        let service = makeService()
        service.add(title: "一次", prompt: "整理日志", hour: 14, minute: 0, repeatsDaily: false)
        let fired = service.fireDueTriggers(now: date(hour: 14, minute: 0))
        XCTAssertEqual(fired.count, 1)
        XCTAssertFalse(service.triggers.first!.enabled, "一次性任务触发后应自动停用")
    }

    func testInvalidTriggerRejected() {
        let service = makeService()
        service.add(title: "", prompt: "   ", hour: 9, minute: 0, repeatsDaily: true)
        XCTAssertTrue(service.triggers.isEmpty)
    }
}
