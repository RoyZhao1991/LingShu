import XCTest
@testable import LingShuMac

@MainActor
final class TaskArtifactDeltaTests: XCTestCase {
    private actor ResumeWritesFileSession: LingShuAgentSessioning {
        let fileURL: URL
        var isBlocked: Bool { false }
        var turnsUsed: Int { 0 }
        var toolInvocations: [String] { [] }
        var messages: [LingShuAgentMessage] { [] }

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func setTextDeltaSink(_ sink: (@Sendable (String) async -> Void)?) {}

        func send(_ userText: String) async -> LingShuAgentRunResult {
            .completed(text: "初始完成")
        }

        func resume(_ answer: String) async -> LingShuAgentRunResult {
            try? Data("fake-docx-after-revision".utf8).write(to: fileURL)
            return .completed(text: "已生成 Word 文档:\(fileURL.path)")
        }

        func continueLoop() async -> LingShuAgentRunResult {
            .completed(text: "继续完成")
        }

        func injectCorrection(_ text: String) -> Bool { false }
        func injectBriefing(_ text: String) {}
    }

    func testSubtaskShadowGitDeltaRegistersCommandGeneratedArtifact() async throws {
        guard !LingShuState.gitCandidatePaths().isEmpty else { throw XCTSkip("本机无可用 git") }
        let state = LingShuState()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-artifact-delta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        state.agentWorkingDirectory = dir.path
        let recordID = state.createTaskExecutionRecord(for: "生成 Word 文档")
        let subID = "task-test-\(UUID().uuidString.prefix(6))"
        state.agentSubTaskRecords[subID] = recordID
        state.agentSubTaskWorkingDirectories[subID] = dir.path

        let existing = dir.appendingPathComponent("stock_analysis_report_20260708.md")
        try "# report\n".write(to: existing, atomically: true, encoding: .utf8)
        state.appendTaskRecordArtifact(recordID, title: existing.lastPathComponent, location: existing.path, producer: "测试", operation: .created)

        await state.prepareSubtaskArtifactDelta(subID: subID, recordID: recordID, workingDirectory: dir.path)
        guard state.agentSubTaskArtifactBaselines[subID] != nil else {
            throw XCTSkip("ShadowGit 基线不可用")
        }

        let generated = dir.appendingPathComponent("stock_analysis_report_20260708.docx")
        try Data("fake-docx".utf8).write(to: generated)

        let countBaseline = state.takeSubtaskArtifactCountBaseline(subID: subID, recordID: recordID)
        await state.registerSubtaskArtifactsFromGitDelta(subID: subID)

        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == recordID })
        XCTAssertEqual(countBaseline, 1)
        XCTAssertTrue(record.artifacts.contains { $0.location == generated.path }, "脚本静默生成的 docx 应通过 git delta 进入产物清单")
    }

    func testRevisionResumeRegistersArtifactGeneratedAfterInitialDelta() async throws {
        guard !LingShuState.gitCandidatePaths().isEmpty else { throw XCTSkip("本机无可用 git") }
        let state = LingShuState()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-artifact-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        state.agentWorkingDirectory = dir.path
        let recordID = state.createTaskExecutionRecord(for: "生成 Markdown 后返工转换 Word")
        let subID = "task-revision-\(UUID().uuidString.prefix(6))"
        state.agentSubTaskRecords[subID] = recordID
        state.agentSubTaskWorkingDirectories[subID] = dir.path

        let markdown = dir.appendingPathComponent("北航MEM案例大赛组织方案.md")
        try "# 方案\n".write(to: markdown, atomically: true, encoding: .utf8)
        state.appendTaskRecordArtifact(recordID, title: markdown.lastPathComponent, location: markdown.path, producer: "测试", operation: .created)

        let word = dir.appendingPathComponent("北航MEM案例大赛组织方案.docx")
        let session = ResumeWritesFileSession(fileURL: word)

        _ = await state.resumeSessionRegisteringArtifactDelta(session, prompt: "验收要求补交 Word 版本", taskRecordID: recordID)

        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == recordID })
        XCTAssertTrue(record.artifacts.contains { $0.location == markdown.path })
        XCTAssertTrue(record.artifacts.contains { $0.location == word.path }, "返工 resume 中生成的 docx 必须补登进同一条任务产物清单")
    }

    func testMentionedExistingFileBackfillIsLimitedToTrustedTaskDirectory() throws {
        let state = LingShuState()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-artifact-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        state.agentWorkingDirectory = dir.path
        let recordID = state.createTaskExecutionRecord(for: "生成组织方案")

        let markdown = dir.appendingPathComponent("北航MEM案例大赛组织方案.md")
        let word = dir.appendingPathComponent("北航MEM案例大赛组织方案.docx")
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-outside-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: outside) }

        try "# 方案\n".write(to: markdown, atomically: true, encoding: .utf8)
        try Data("word".utf8).write(to: word)
        try Data("outside".utf8).write(to: outside)
        state.appendTaskRecordArtifact(recordID, title: markdown.lastPathComponent, location: markdown.path, producer: "测试", operation: .created)

        guard let index = state.taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else {
            return XCTFail("record missing")
        }
        state.taskExecutionRecords[index].summary = """
        已生成 Markdown:\(markdown.path)
        已生成 Word:\(word.path)
        参考旧文件:\(outside.path)
        """

        let added = state.reconcileTaskRecordArtifactsFromMentionedExistingFiles(recordID: recordID)
        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == recordID })

        XCTAssertEqual(added, 1)
        XCTAssertTrue(record.artifacts.contains { $0.location == word.path })
        XCTAssertFalse(record.artifacts.contains { $0.location == outside.path }, "补登只能收本任务可信目录内的文件,避免历史旧文件串台")
    }

    func testFilenameOnlyDeliveryBackfillsAllTrustedArtifactsWithoutDuplicates() throws {
        let state = LingShuState()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-artifact-filename-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        state.agentWorkingDirectory = dir.path
        let recordID = state.createTaskExecutionRecord(for: "生成项目启动材料")
        let deck = dir.appendingPathComponent("Project Helios Launch Kit.pptx")
        let brief = dir.appendingPathComponent("Project_Helios_Launch_Brief.docx")
        try Data("deck".utf8).write(to: deck)
        try Data("brief".utf8).write(to: brief)
        state.appendTaskRecordArtifact(
            recordID,
            title: deck.lastPathComponent,
            location: deck.path,
            producer: "测试",
            operation: .created
        )

        guard let index = state.taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else {
            return XCTFail("record missing")
        }
        state.taskExecutionRecords[index].summary = """
        Delivered `Project Helios Launch Kit.pptx` and **Project_Helios_Launch_Brief.docx**.
        """

        let added = state.reconcileTaskRecordArtifactsFromMentionedExistingFiles(recordID: recordID)
        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == recordID })
        let canonicalBrief = brief.resolvingSymlinksInPath().standardizedFileURL.path

        XCTAssertEqual(added, 1, "artifacts=\(record.artifacts.map(\.location))")
        XCTAssertEqual(record.artifacts.filter { $0.location == deck.path }.count, 1)
        XCTAssertEqual(record.artifacts.filter {
            URL(fileURLWithPath: $0.location).resolvingSymlinksInPath().standardizedFileURL.path == canonicalBrief
        }.count, 1)
    }

    func testFilenameMentionedOnlyByUserDoesNotBackfillArtifact() throws {
        let state = LingShuState()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-artifact-user-mention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        state.agentWorkingDirectory = dir.path
        let filename = "existing_report_\(UUID().uuidString).docx"
        let file = dir.appendingPathComponent(filename)
        try Data("old".utf8).write(to: file)
        let recordID = state.createTaskExecutionRecord(for: "请读取 \(filename) 后给建议")

        let added = state.reconcileTaskRecordArtifactsFromMentionedExistingFiles(recordID: recordID)
        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == recordID })

        XCTAssertEqual(added, 0)
        XCTAssertFalse(record.artifacts.contains { $0.location == file.path })
    }

    func testFilenameOnlyBackfillRejectsSymlinkEscapingTrustedDirectory() throws {
        let state = LingShuState()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lingshu-artifact-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outside-secret-\(UUID().uuidString).docx")
        let link = dir.appendingPathComponent("Final_Brief.docx")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        state.agentWorkingDirectory = dir.path
        let recordID = state.createTaskExecutionRecord(for: "生成最终简报")
        guard let index = state.taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else {
            return XCTFail("record missing")
        }
        state.taskExecutionRecords[index].summary = "Delivered Final_Brief.docx"

        let added = state.reconcileTaskRecordArtifactsFromMentionedExistingFiles(recordID: recordID)
        let record = try XCTUnwrap(state.taskExecutionRecords.first { $0.id == recordID })

        XCTAssertEqual(added, 0)
        XCTAssertTrue(record.artifacts.isEmpty)
    }
}
