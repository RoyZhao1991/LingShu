import XCTest
@testable import LingShuMac

@MainActor
final class LongCommandCompletionTests: XCTestCase {
    func testFiniteLongCommandPreventsPrematureCompletionAndResumesWithTerminalEvidence() async {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "run a finite hosted command")
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-long-completion-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
            try? FileManager.default.removeItem(at: workspace)
        }

        let job = state.longCommandRegistry.start(
            command: "sleep 0.2; printf 'codex-review-done\\n'",
            workingDirectory: workspace.path,
            label: "Codex review",
            timeoutSeconds: 30
        )
        state.awaitedLongCommandJobIDsByRecord[recordID] = [job.id]

        let model = LingShuScriptedAgentModel([.text("final delivery after review")])
        let session = LingShuAgentSession(id: "long-command-completion", tools: [], model: model, maxTurns: 3)
        let result = await state.continueAfterAwaitedLongCommands(
            session: session,
            result: .completed(text: job.modelText),
            taskRecordID: recordID
        )

        guard case .completed(let text) = result else {
            return XCTFail("expected resumed completion, got \(result)")
        }
        XCTAssertEqual(text, "final delivery after review")
        XCTAssertEqual(state.longCommandRegistry.snapshot(id: job.id)?.status, .succeeded)
        XCTAssertNil(state.awaitedLongCommandJobIDsByRecord[recordID])
        let messages = await session.messages
        XCTAssertTrue(messages.contains { $0.role == .user && $0.content.contains("codex-review-done") })
    }

    func testStartLongCommandDefaultsToAwaitButBackgroundDoesNotBlockCompletion() async {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "start hosted commands")
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-long-mode-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            for snapshot in state.longCommandRegistry.snapshots() where !snapshot.status.isTerminal {
                _ = state.longCommandRegistry.cancel(id: snapshot.id)
            }
            state.awaitedLongCommandJobIDsByRecord[recordID] = nil
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
            try? FileManager.default.removeItem(at: workspace)
        }

        let tools = state.longCommandTools(
            recordIDProvider: { recordID },
            baseAllowShell: true,
            defaultWorkingDirectory: workspace.path,
            workingDirectoryOverride: nil
        )
        guard let start = tools.first(where: { $0.name == "start_long_command" }) else {
            return XCTFail("missing start_long_command")
        }
        guard let check = tools.first(where: { $0.name == "check_long_command" }) else {
            return XCTFail("missing check_long_command")
        }

        let finiteOutput = await start.handler(#"{"command":"sleep 0.2; echo finite-done","label":"finite"}"#)
        let finiteID = Self.jobID(in: finiteOutput)
        XCTAssertNotNil(finiteID)
        XCTAssertTrue(state.awaitedLongCommandJobIDsByRecord[recordID]?.contains(finiteID ?? "") == true)

        try? await Task.sleep(nanoseconds: 500_000_000)
        let checked = await check.handler("{\"job_id\":\"\(finiteID ?? "")\"}")
        XCTAssertTrue(checked.contains("长命令 已完成"))
        XCTAssertNil(state.awaitedLongCommandJobIDsByRecord[recordID])

        let backgroundOutput = await start.handler(#"{"command":"sleep 2; echo background","label":"service","completion_mode":"background"}"#)
        let backgroundID = Self.jobID(in: backgroundOutput)
        XCTAssertNotNil(backgroundID)
        XCTAssertFalse(state.awaitedLongCommandJobIDsByRecord[recordID]?.contains(backgroundID ?? "") == true)
    }

    func testOnlyTerminalLikeResultsMayResumeAfterHostedCommand() {
        XCTAssertTrue(LingShuState.canContinueAfterLongCommand(.completed(text: "done")))
        XCTAssertTrue(LingShuState.canContinueAfterLongCommand(.maxTurnsReached(lastText: "pending")))
        XCTAssertFalse(LingShuState.canContinueAfterLongCommand(.blocked(question: "confirm")))
        XCTAssertFalse(LingShuState.canContinueAfterLongCommand(.interrupted(reason: "offline")))
    }

    private static func jobID(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0.hasPrefix("job_id:") }?
            .dropFirst("job_id:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
