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

    /// 关键回归：定时器被后台暂停错过了精确的那一分钟，进入追赶窗口后仍能补触发（不再永久错过）。
    func testCatchUpFiresAfterMissedExactMinute() {
        let service = makeService()
        service.add(title: "喝水", prompt: "提醒我喝水", hour: 9, minute: 30, repeatsDaily: true)
        // 9:30 那一分钟没人 tick（UI 定时器被后台暂停），下一次 tick 落在 9:33。
        let fired = service.fireDueTriggers(now: date(hour: 9, minute: 33))
        XCTAssertEqual(fired.count, 1, "错过精确分钟后应在追赶窗口内补触发")
        // 同一次「当天到点」不重复触发。
        XCTAssertTrue(service.fireDueTriggers(now: date(hour: 9, minute: 34)).isEmpty)
        XCTAssertTrue(service.triggers.first!.enabled, "每日任务仍启用")
    }

    /// 追赶窗口外（关机一整天后开机等）不再补触发，避免「上午 9 点的提醒」在晚上离谱地弹出来。
    func testCatchUpWindowStopsStaleFire() {
        let service = makeService()
        service.add(title: "晨会", prompt: "提醒开晨会", hour: 9, minute: 0, repeatsDaily: true)
        // 距离 9:00 已过去约 11 小时，远超默认 1 小时追赶窗口。
        XCTAssertTrue(service.fireDueTriggers(now: date(hour: 20, minute: 0)).isEmpty)
    }

    /// fireAfter 下界：一次性任务在「最早允许时间」之前不触发，到了之后才触发。
    func testFireAfterDefersOneShotUntilAllowed() {
        let service = makeService()
        let tomorrowTen = Calendar.current.date(byAdding: .day, value: 1, to: date(hour: 10, minute: 0))!
        service.add(title: "明天汇报", prompt: "汇总进展", hour: 10, minute: 0, repeatsDaily: false, fireAfter: tomorrowTen)
        // 今天 10:00 到点了，但 fireAfter 是明天 → 不触发。
        XCTAssertTrue(service.fireDueTriggers(now: date(hour: 10, minute: 0)).isEmpty, "未到 fireAfter 不触发")
        // 明天 10:00 之后 → 触发并停用。
        let fired = service.fireDueTriggers(now: tomorrowTen.addingTimeInterval(10))
        XCTAssertEqual(fired.count, 1)
        XCTAssertFalse(service.triggers.first!.enabled, "一次性触发后停用")
    }

    /// 纯函数：下一次该时刻 = 今天若还没到则今天，否则明天。
    func testNextOccurrencePureFunction() {
        let cal = Calendar.current
        let now = date(hour: 8, minute: 0)
        let ahead = LingShuState.nextOccurrence(hour: 9, minute: 0, from: now, calendar: cal)
        XCTAssertEqual(cal.component(.day, from: ahead), cal.component(.day, from: now), "9:00 还没到 → 今天")
        let behindNow = date(hour: 10, minute: 0)
        let behind = LingShuState.nextOccurrence(hour: 9, minute: 0, from: behindNow, calendar: cal)
        XCTAssertGreaterThan(behind, behindNow, "9:00 已过 → 明天")
    }

    /// 纯函数：fireAfter 解析——每日重复=nil；指定日期=那天该时刻；一次性无日期=下一次该时刻。
    func testScheduledFireAfterParsing() {
        let cal = Calendar.current
        let now = date(hour: 8, minute: 0)
        XCTAssertNil(LingShuState.scheduledFireAfter(dateString: nil, hour: 9, minute: 0, now: now, calendar: cal, repeatsDaily: true))
        let dated = LingShuState.scheduledFireAfter(dateString: "2030-01-15", hour: 10, minute: 30, now: now, calendar: cal, repeatsDaily: false)
        XCTAssertNotNil(dated)
        XCTAssertEqual(cal.component(.year, from: dated!), 2030)
        XCTAssertEqual(cal.component(.hour, from: dated!), 10)
        let oneShot = LingShuState.scheduledFireAfter(dateString: nil, hour: 9, minute: 0, now: now, calendar: cal, repeatsDaily: false)
        XCTAssertEqual(oneShot, LingShuState.nextOccurrence(hour: 9, minute: 0, from: now, calendar: cal))
    }

    func testScheduledTriggerPromptInjectsAuthoritativeDateAnchor() {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let firedAt = calendar.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 8, minute: 0, second: 0))!
        let trigger = LingShuScheduledTrigger(
            title: "早间新闻",
            prompt: "搜索今天早上8点左右的国内外重要新闻并朗读，保存为今日热点新闻摘要.md",
            hour: 8,
            minute: 0,
            repeatsDaily: true
        )

        let prompt = LingShuState.scheduledTriggerPrompt(trigger: trigger, firedAt: firedAt, timeZone: timeZone)

        XCTAssertTrue(prompt.contains("权威本地时间：2026-06-23 08:00:00"))
        XCTAssertTrue(prompt.contains("ISO 日期：2026-06-23"))
        XCTAssertTrue(prompt.contains("日期戳：20260623"))
        XCTAssertTrue(prompt.contains("文件名时，日期必须使用 20260623"))
        XCTAssertTrue(prompt.contains(trigger.prompt))
        XCTAssertFalse(prompt.contains("20250718"), "定时任务不得继承历史产物中的错误日期")
    }
}
