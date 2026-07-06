import XCTest
@testable import LingShuMac

final class TaskThreadLedgerTests: XCTestCase {
    @MainActor
    func testNewTaskRecordCreatesInitialThreadCommit() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "测试任务线程账本:创建任务")
        defer { cleanup(recordID: recordID, state: state) }

        let record = state.taskExecutionRecords.first { $0.id == recordID }
        XCTAssertEqual(record?.threadCommit?.status, .running)
        XCTAssertEqual(record?.threadCommit?.phase, .planning)
        XCTAssertEqual(record?.threadCommit?.taskId, recordID)
    }

    @MainActor
    func testWaitingForUserCommitKeepsRequiredActionVisible() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "测试任务线程账本:等待用户")
        defer { cleanup(recordID: recordID, state: state) }

        state.commitTaskThreadState(
            recordID: recordID,
            status: .waitingForUser,
            phase: .waiting,
            summary: "需要提供授权",
            blockingReason: "外部系统需要授权",
            requiredUserAction: "提供授权后继续"
        )

        let commit = state.taskExecutionRecords.first { $0.id == recordID }?.threadCommit
        XCTAssertEqual(commit?.status, .waitingForUser)
        XCTAssertEqual(commit?.requiredUserAction, "提供授权后继续")
        XCTAssertTrue(state.globalTaskThreadLedgerContext().contains("提供授权后继续"))
    }

    @MainActor
    func testFinishedRecordCommitIncludesArtifactsAndMCPPayload() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "测试任务线程账本:完成并登记产物")
        defer { cleanup(recordID: recordID, state: state) }

        state.appendTaskRecordArtifact(recordID, title: "测试产物", location: "/tmp/lingshu-ledger-test.txt", producer: "测试")
        state.finishTaskRecord(recordID, status: .verified, summary: "测试任务已核验")

        let record = state.taskExecutionRecords.first { $0.id == recordID }
        XCTAssertEqual(record?.threadCommit?.status, .verified)
        XCTAssertEqual(record?.threadCommit?.phase, .delivering)
        XCTAssertEqual(record?.threadCommit?.artifacts.first?.location, "/tmp/lingshu-ledger-test.txt")

        let payload = record?.threadCommit.map(LingShuState.taskThreadCommitPayload)
        XCTAssertEqual(payload?["status"] as? String, LingShuTaskExecutionStatus.verified.rawValue)
        XCTAssertEqual(payload?["phase"] as? String, LingShuTaskThreadCommit.Phase.delivering.rawValue)
    }

    @MainActor
    func testStructuredFinishSummaryOnlyShowsVisibleReply() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "测试任务线程账本:结构化收尾不泄露 JSON")
        defer { cleanup(recordID: recordID, state: state) }

        state.chatMessages.append(.init(
            speaker: "灵枢",
            text: "",
            isUser: false,
            isLoading: true,
            taskRecordID: recordID
        ))

        let rawSummary = """
        {
          "reply": "文件路径：/tmp/lingshu-visible-summary.txt，验证通过。",
          "completion": {
            "status": "ok",
            "reason": "done",
            "needs_user": false
          },
          "user_input": null,
          "inability": null,
          "OAuth": null
        }
        """

        state.finishTaskRecord(recordID, status: .completed, summary: rawSummary)

        let record = state.taskExecutionRecords.first { $0.id == recordID }
        XCTAssertEqual(record?.summary, "文件路径：/tmp/lingshu-visible-summary.txt，验证通过。")
        XCTAssertEqual(record?.threadCommit?.progressSummary, "文件路径：/tmp/lingshu-visible-summary.txt，验证通过。")

        let bubble = state.chatMessages.last { $0.taskRecordID == recordID && !$0.isUser }
        XCTAssertEqual(bubble?.text, "✅ 文件路径：/tmp/lingshu-visible-summary.txt，验证通过。")
        XCTAssertFalse(bubble?.text.contains("\"reply\"") ?? true)
        XCTAssertFalse(state.globalTaskThreadLedgerContext().contains("\"reply\""))
    }

    @MainActor
    func testAnsweredRecordUpgradesToCompletedWhenArtifactIsRegistered() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "测试任务线程账本:终态后补登产物")
        defer { cleanup(recordID: recordID, state: state) }

        state.finishTaskRecord(recordID, status: .answered, summary: "文件已写入")
        XCTAssertEqual(state.taskExecutionRecords.first { $0.id == recordID }?.status, .answered)

        state.appendTaskRecordArtifact(recordID, title: "结果文件", location: "/tmp/lingshu-upgrade-artifact.txt", producer: "测试")

        let record = state.taskExecutionRecords.first { $0.id == recordID }
        XCTAssertEqual(record?.status, .completed)
        XCTAssertEqual(record?.threadCommit?.status, .completed)
        XCTAssertEqual(record?.threadCommit?.phase, .delivering)
    }

    @MainActor
    func testRecentCompletedTaskIsNotStarvedByOldOpenTasks() {
        let state = LingShuState()
        var recordIDs: [String] = []
        defer {
            for id in recordIDs { cleanup(recordID: id, state: state) }
        }

        let oldBase = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<6 {
            let recordID = state.createTaskExecutionRecord(for: "旧的待续任务 \(index)")
            recordIDs.append(recordID)
            guard let i = state.taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else { continue }
            state.taskExecutionRecords[i].status = .waitingForUser
            state.taskExecutionRecords[i].summary = "旧任务等待用户 \(index)"
            _ = state.taskExecutionRecords[i].refreshThreadCommit(
                status: .waitingForUser,
                phase: .waiting,
                summary: "旧任务等待用户 \(index)",
                now: oldBase.addingTimeInterval(Double(index))
            )
        }

        let latestID = state.createTaskExecutionRecord(for: "最新完成任务必须进入主线程账本")
        recordIDs.append(latestID)
        state.appendTaskRecordArtifact(latestID, title: "最新产物", location: "/tmp/latest-ledger.txt", producer: "测试")
        state.finishTaskRecord(latestID, status: .verified, summary: "最新任务已完成")

        let payload = state.globalTaskThreadLedgerPayload(limit: 3)
        let ids = payload.compactMap { $0["taskId"] as? String }
        XCTAssertTrue(ids.contains(latestID), "主线程账本应优先给最近活动的任务留位置,不能被旧的未完成任务长期挤掉")
    }

    @MainActor
    private func cleanup(recordID: String, state: LingShuState) {
        state.taskExecutionRecords.removeAll { $0.id == recordID }
        state.persistTaskExecutionRecords()
    }
}
