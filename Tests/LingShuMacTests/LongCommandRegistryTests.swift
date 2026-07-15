import XCTest
@testable import LingShuMac

@MainActor
final class LongCommandRegistryTests: XCTestCase {
    private var tempDir: URL!
    private var logDir: URL!
    private var registry: LingShuLongCommandRegistry!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lingshu-longcmd-\(UUID().uuidString)", isDirectory: true)
        logDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        registry = LingShuLongCommandRegistry(logDirectory: logDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        registry = nil
    }

    func testLongCommandCompletesAndKeepsLogTail() async {
        let started = registry.start(
            command: "printf 'hello-long-command\\n'",
            workingDirectory: tempDir.path,
            label: "unit",
            timeoutSeconds: 30
        )
        XCTAssertEqual(started.status, .running)

        let done = await waitUntilTerminal(jobID: started.id)
        XCTAssertEqual(done?.status, .succeeded)
        XCTAssertTrue(done?.tail.contains("hello-long-command") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: done?.logPath ?? ""))
    }

    func testStartDeduplicatesSameRunningCommand() async {
        let command = "sleep 1; echo dedupe-ok"
        let first = registry.start(command: command, workingDirectory: tempDir.path, label: "dedupe", timeoutSeconds: 30)
        let second = registry.start(command: command, workingDirectory: tempDir.path, label: "dedupe", timeoutSeconds: 30)

        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(first.reusedExisting)
        XCTAssertTrue(second.reusedExisting)

        let done = await waitUntilTerminal(jobID: first.id)
        XCTAssertEqual(done?.status, .succeeded)
        XCTAssertTrue(done?.tail.contains("dedupe-ok") == true)
    }

    func testCancelStopsRunningCommand() async {
        let started = registry.start(
            command: "sleep 30; echo should-not-print",
            workingDirectory: tempDir.path,
            label: "cancel",
            timeoutSeconds: 60
        )
        let cancelled = registry.cancel(id: started.id)
        XCTAssertEqual(cancelled?.status, .cancelled)

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let latest = registry.snapshot(id: started.id)
        XCTAssertEqual(latest?.status, .cancelled)
        XCTAssertNotNil(latest?.endedAt)
    }

    private func waitUntilTerminal(jobID: String, timeout: TimeInterval = 8) async -> LingShuLongCommandSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = registry.snapshot(id: jobID), snapshot.status.isTerminal {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return registry.snapshot(id: jobID)
    }
}
