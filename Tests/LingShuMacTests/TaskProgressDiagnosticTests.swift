import XCTest
@testable import LingShuMac

final class TaskProgressDiagnosticTests: XCTestCase {
    @MainActor
    func testProgressDiagnosticExposesCurrentPlanAndToolAction() throws {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "生成一份测试报告")
        defer { cleanup(recordID: recordID, state: state) }

        guard let index = state.taskExecutionRecords.firstIndex(where: { $0.id == recordID }) else {
            return XCTFail("record should exist")
        }
        state.taskExecutionRecords[index].plan = [
            .init(title: "读取资料", status: .completed),
            .init(title: "生成报告文件", status: .inProgress)
        ]
        state.appendTaskRecordMessage(
            recordID,
            actor: "工具",
            role: "命令",
            kind: .agent,
            text: "",
            detail: .toolCall(tool: "run_command", summary: "正在调用脚本生成 Word 文档", arguments: "{}")
        )
        state.appendTrace(kind: .tool, actor: "工具", title: "调用命令", detail: "recordID=\(recordID) 生成报告文件")

        let diagnostic = try XCTUnwrap(state.activityDiagnostic(for: recordID))
        XCTAssertTrue(diagnostic.headline.contains("生成报告文件"))
        XCTAssertTrue(diagnostic.detail.contains("工具调用：跑命令"))
        XCTAssertTrue(diagnostic.lastTrace?.contains("调用命令") ?? false)
        XCTAssertNotEqual(diagnostic.lastTraceTime, "无")
        XCTAssertTrue(diagnostic.currentStep.contains("生成报告文件"))
        XCTAssertEqual(diagnostic.waitState, "等待工具")
        XCTAssertTrue(diagnostic.heartbeatText.contains("心跳"))
        XCTAssertFalse(diagnostic.recordIDShort.isEmpty)
        XCTAssertFalse(diagnostic.isTerminalButLoading)
    }

    @MainActor
    func testTerminalRecordStillLoadingIsDiagnosedAsPendingBubbleCloseout() throws {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "完成后收口")
        defer { cleanup(recordID: recordID, state: state) }

        state.commitTaskThreadState(
            recordID: recordID,
            status: .completed,
            phase: .delivering,
            summary: "已经完成",
            persist: false,
            trace: false
        )

        let diagnostic = try XCTUnwrap(state.activityDiagnostic(for: recordID))
        XCTAssertTrue(diagnostic.isTerminalButLoading)
        XCTAssertTrue(diagnostic.headline.contains("主气泡等待收口"))
        XCTAssertEqual(diagnostic.phase, "交付")
        XCTAssertEqual(diagnostic.waitState, "已结束")
    }

    @MainActor
    private func cleanup(recordID: String, state: LingShuState) {
        state.taskExecutionRecords.removeAll { $0.id == recordID }
        state.persistTaskExecutionRecords()
    }
}
