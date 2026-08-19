import Foundation
import XCTest
@testable import LingShuMac

final class FrontendProjectionPerformanceTests: XCTestCase {
    func testUnchangedKernelSnapshotProducesNoSwiftUIRecordUpdates() {
        let taskID = UUID()
        let assistantID = UUID()
        let snapshot = makeSnapshot(
            taskID: taskID,
            assistantID: assistantID,
            assistantText: "正在整理文档。"
        )

        let initial = LingShuState.prepareSharedKernelProjection(
            snapshot,
            existingRecords: [:],
            previousFingerprints: [:],
            english: false
        )
        XCTAssertEqual(initial.changedTasks.count, 1)

        let unchanged = LingShuState.prepareSharedKernelProjection(
            snapshot,
            existingRecords: [
                taskID.uuidString.lowercased(): initial.changedTasks[0].record,
            ],
            previousFingerprints: initial.fingerprints,
            english: false
        )
        XCTAssertTrue(unchanged.changedTasks.isEmpty)
        XCTAssertEqual(unchanged.fingerprints, initial.fingerprints)
    }

    func testStreamingTextChangeInvalidatesOnlyChangedTaskProjection() {
        let taskID = UUID()
        let assistantID = UUID()
        let initialSnapshot = makeSnapshot(
            taskID: taskID,
            assistantID: assistantID,
            assistantText: "正在整理文档。"
        )
        let initial = LingShuState.prepareSharedKernelProjection(
            initialSnapshot,
            existingRecords: [:],
            previousFingerprints: [:],
            english: false
        )
        let changedSnapshot = makeSnapshot(
            taskID: taskID,
            assistantID: assistantID,
            assistantText: "已经完成提纲，正在生成文档。"
        )

        let changed = LingShuState.prepareSharedKernelProjection(
            changedSnapshot,
            existingRecords: [
                taskID.uuidString.lowercased(): initial.changedTasks[0].record,
            ],
            previousFingerprints: initial.fingerprints,
            english: false
        )

        XCTAssertEqual(changed.changedTasks.count, 1)
        XCTAssertEqual(
            changed.changedTasks[0].bubble?.visibleText,
            "已经完成提纲，正在生成文档。",
            "已有 Loop 正文时，最新工具事件不得覆盖累计输出"
        )
        XCTAssertNotEqual(changed.fingerprints, initial.fingerprints)
    }

    func testRuntimeEventIsFallbackBeforeLoopProducesVisibleText() {
        let taskID = UUID()
        let assistantID = UUID()
        let snapshot = makeSnapshot(
            taskID: taskID,
            assistantID: assistantID,
            assistantText: ""
        )

        let projection = LingShuState.prepareSharedKernelProjection(
            snapshot,
            existingRecords: [:],
            previousFingerprints: [:],
            english: false
        )

        XCTAssertEqual(projection.changedTasks[0].bubble?.visibleText, "读取附件")
    }

    func testTerminatedProjectionKeepsCumulativeAssistantTextAheadOfSummary() {
        let taskID = UUID()
        let assistantID = UUID()
        let visibleWork = "已完成资料整理。\n\n报告前三节已经写入工作区。"
        let snapshot = makeSnapshot(
            taskID: taskID,
            assistantID: assistantID,
            assistantText: visibleWork,
            taskStatus: .cancelled,
            summary: "正在写第四节"
        )

        let projection = LingShuState.prepareSharedKernelProjection(
            snapshot,
            existingRecords: [:],
            previousFingerprints: [:],
            english: false
        )

        XCTAssertEqual(projection.changedTasks[0].bubble?.visibleText, visibleWork)
        XCTAssertEqual(projection.changedTasks[0].bubble?.status, .cancelled)
        XCTAssertFalse(projection.changedTasks[0].bubble?.isLoading ?? true)
        XCTAssertEqual(projection.changedTasks[0].record.status, .terminated)
        XCTAssertTrue(projection.changedTasks[0].record.status.isTerminal)
        XCTAssertFalse(projection.changedTasks[0].record.status.isResumableUnfinished)
        XCTAssertEqual(LingShuState.sharedKernelPlanStatus(.cancelled), .cancelled)
        XCTAssertEqual(LingShuState.sharedKernelRoleStatus(.cancelled), .cancelled)
    }

    func testPathPresentationDetectsAndHidesPathInSinglePass() {
        let path = "/tmp/LingShu Frontend/report.docx"
        let text = "Word 文档：`\(path)` — 已生成"
        var fileChecks = 0

        let presentation = LingShuLocalPathDetector.presentation(in: text) { candidate in
            fileChecks += 1
            return candidate == path
        }

        XCTAssertEqual(presentation.paths, [path])
        XCTAssertFalse(presentation.displayText.contains(path))
        XCTAssertEqual(fileChecks, 1, "一次渲染不应分别为显示文本和预览链接重复访问文件系统")
    }

    private func makeSnapshot(
        taskID: UUID,
        assistantID: UUID,
        assistantText: String,
        taskStatus: LingShuKernelTaskStatus = .running,
        summary: String = ""
    ) -> LingShuKernelRuntimeSnapshot {
        let timestamp = "2026-08-03T10:00:00Z"
        let task = LingShuKernelTaskRecord(
            id: taskID,
            title: "生成文档",
            prompt: "整理材料并生成文档",
            status: taskStatus,
            createdAt: timestamp,
            updatedAt: timestamp,
            goalSpec: nil,
            steps: [],
            artifacts: [],
            summary: summary,
            error: nil,
            assistantMessageId: assistantID,
            attachmentPaths: [],
            parentTaskId: nil,
            rootTaskId: taskID,
            role: .main,
            origin: .conversation,
            participantName: "LingShu",
            depth: 0,
            loopEngine: .grok,
            pendingQuestion: nil
        )
        let message = LingShuKernelChatMessage(
            id: assistantID,
            role: .assistant,
            text: assistantText,
            createdAt: timestamp,
            state: .thinking,
            threadId: taskID
        )
        let event = LingShuKernelRuntimeEvent(
            id: UUID(),
            sequence: 1,
            taskId: taskID,
            parentTaskId: nil,
            kind: .tool,
            state: .running,
            actor: "LingShu",
            title: "读取附件",
            detail: "正在读取附件。",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return LingShuKernelRuntimeSnapshot(
            kernelAbiVersion: LingShuKernelABI.version,
            settings: LingShuKernelRuntimeSettings(
                locale: .zhCN,
                providerId: "test",
                providerName: "Test",
                protocol: .openAIChatCompletions,
                endpoint: "http://127.0.0.1:9",
                model: "test-model",
                workspace: "/tmp",
                executionPermissionMode: .sandbox,
                loopEngine: .grok,
                firstRunComplete: true
            ),
            platform: "macos",
            capabilities: LingShuKernelPlatformCapabilities(
                computerControl: true,
                realtimePerception: true,
                internalPreview: true,
                externalOpen: true
            ),
            messages: [message],
            tasks: [task],
            activeTaskId: taskID,
            queuedTaskCount: 0,
            providerConfigured: true,
            events: [event],
            latestEventSequence: 1,
            memory: nil,
            loopEngines: []
        )
    }
}
