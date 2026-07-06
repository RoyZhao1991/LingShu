import XCTest
@testable import LingShuMac

final class ContextAssemblyTraceTests: XCTestCase {
    private func builtinAgentTools() throws -> [LingShuAgentTool] {
        try LingShuFunctionCallingCatalog.builtin.map { definition in
            let data = try JSONSerialization.data(withJSONObject: definition.wireObject())
            return LingShuAgentTool(
                name: definition.name,
                description: definition.description,
                parametersJSON: String(data: data, encoding: .utf8) ?? "{}"
            ) { _ in
                ""
            }
        }
    }

    func testContextAssemblyPlanUsesStructuredTrace() {
        let active = LingShuContextAssemblyPlan.mainActiveTurn(
            source: "structured_route_none",
            reason: "brain_decides_reply_or_task"
        )
        XCTAssertEqual(active.strategy, .mainActiveTurn)
        XCTAssertNil(active.targetRecordID)
        XCTAssertTrue(active.includeMainRecentContext)
        XCTAssertFalse(active.includeTaskMemory)
        XCTAssertEqual(active.toolScope, .full)
        XCTAssertTrue(active.traceLine.contains("stage=5"))
        XCTAssertTrue(active.traceLine.contains("strategy=main_active_turn"))
        XCTAssertTrue(active.traceLine.contains("record=none"))
        XCTAssertTrue(active.traceLine.contains("source=structured_route_none"))

        let continuation = LingShuContextAssemblyPlan.continueExistingTask(
            recordID: "record-1",
            source: "structured_route_reply",
            reason: "resume_dispatched_thread"
        )
        XCTAssertEqual(continuation.strategy, .continueExistingTask)
        XCTAssertEqual(continuation.targetRecordID, "record-1")
        XCTAssertTrue(continuation.includeTaskMemory)
        XCTAssertEqual(continuation.toolScope, .task)
        XCTAssertTrue(continuation.traceLine.contains("strategy=continue_existing_task"))
        XCTAssertTrue(continuation.traceLine.contains("record=record-1"))
        XCTAssertTrue(continuation.traceLine.contains("taskMemory=on"))

        let legacy = LingShuContextAssemblyPlan.legacyTaskTurn(
            recordID: "record-2",
            source: "legacy_task_route",
            reason: "foreground_interaction"
        )
        XCTAssertEqual(legacy.strategy, .legacyTaskTurn)
        XCTAssertEqual(legacy.targetRecordID, "record-2")
        XCTAssertTrue(legacy.includeMainRecentContext)
        XCTAssertTrue(legacy.includeTaskMemory)
        XCTAssertEqual(legacy.toolScope, .full)
        XCTAssertTrue(legacy.traceLine.contains("strategy=legacy_task_turn"))
        XCTAssertTrue(legacy.traceLine.contains("record=record-2"))
        XCTAssertTrue(legacy.traceLine.contains("source=legacy_task_route"))
    }

    func testSnapshotBreaksDownMessagesToolsAndImages() throws {
        let messages: [LingShuAgentMessage] = [
            .init(role: .system, content: "你是灵枢。请保持上下文。"),
            .init(role: .user, content: "继续介绍自己", imageDataURLs: ["data:image/png;base64,abc"]),
            .init(
                role: .assistant,
                content: "我会先判断上下文。",
                toolCalls: [.init(id: "call_1", name: "read_file", argumentsJSON: #"{"path":"/tmp/a"}"#)]
            ),
            .init(role: .tool, content: "read_file: ok", toolCallID: "call_1")
        ]
        let tools = try builtinAgentTools()

        let snapshot = LingShuContextAssemblySnapshot.make(
            provider: "unit",
            model: "measurement",
            protocolName: "OpenAI",
            stream: true,
            hasContinuationToken: true,
            messages: messages,
            tools: tools
        )

        XCTAssertEqual(snapshot.messageCount, 4)
        XCTAssertEqual(snapshot.systemMessageCount, 1)
        XCTAssertEqual(snapshot.userMessageCount, 1)
        XCTAssertEqual(snapshot.assistantMessageCount, 1)
        XCTAssertEqual(snapshot.toolResultMessageCount, 1)
        XCTAssertEqual(snapshot.imageCount, 1)
        XCTAssertEqual(snapshot.toolCount, 6)
        XCTAssertGreaterThan(snapshot.toolPropertyCount, 0)
        XCTAssertGreaterThan(snapshot.toolSchemaChars, 0)
        XCTAssertGreaterThan(snapshot.toolCallArgumentChars, 0)
        XCTAssertEqual(snapshot.estimatedInputTokens, snapshot.estimatedTextTokens + snapshot.estimatedToolSchemaTokens + snapshot.estimatedImageTokens)
        XCTAssertTrue(snapshot.startLogLine.contains("context-assembly"))
    }

    func testMeterRecordsLifecycleAndCacheRate() throws {
        let meter = LingShuContextAssemblyMeter.shared
        meter.reset()

        let snapshot = LingShuContextAssemblySnapshot.make(
            provider: "unit",
            model: "measurement",
            protocolName: "OpenAI",
            stream: false,
            hasContinuationToken: false,
            messages: [.init(role: .user, content: "普通问题")],
            tools: []
        )
        let startedAt = Date().addingTimeInterval(-0.2)
        let begun = meter.begin(snapshot)
        let finished = meter.finish(
            id: begun.id,
            promptTokens: 1_000,
            cachedTokens: 250,
            totalTokens: 1_050,
            startedAt: startedAt,
            responseKind: "text"
        )

        let latest = try XCTUnwrap(finished)
        XCTAssertEqual(latest.promptTokens, 1_000)
        XCTAssertEqual(latest.cachedTokens, 250)
        XCTAssertEqual(latest.actualCacheRatePercent, 25)
        XCTAssertEqual(latest.totalTokens, 1_050)
        XCTAssertEqual(latest.responseKind, "text")
        XCTAssertGreaterThanOrEqual(latest.latencyMs ?? 0, 0)
        XCTAssertTrue(latest.finishLogLine.contains("cacheRate=25%"))
        XCTAssertTrue(latest.reportLine.contains("工具 0"))
        XCTAssertEqual(meter.recent(limit: 1).first?.id, begun.id)
    }

    func testFailedRequestStillKeepsAssemblyRecord() throws {
        let meter = LingShuContextAssemblyMeter.shared
        meter.reset()

        let begun = meter.begin(.make(
            provider: "unit",
            model: "measurement",
            protocolName: "OpenAI",
            stream: true,
            hasContinuationToken: false,
            messages: [.init(role: .user, content: "需要一个工具")],
            tools: try builtinAgentTools()
        ))

        let finished = meter.finish(
            id: begun.id,
            promptTokens: nil,
            cachedTokens: nil,
            totalTokens: nil,
            startedAt: Date(),
            responseKind: "failed_stream",
            errorKind: "quota_exceeded"
        )

        let latest = try XCTUnwrap(finished)
        XCTAssertEqual(latest.responseKind, "failed_stream")
        XCTAssertEqual(latest.errorKind, "quota_exceeded")
        XCTAssertTrue(latest.finishLogLine.contains("error=quota_exceeded"))
    }

    func testMeterKeepsRecentSnapshotsWithinLimit() {
        let meter = LingShuContextAssemblyMeter.shared
        meter.reset()

        for i in 0..<140 {
            _ = meter.begin(.make(
                provider: "unit",
                model: "measurement-\(i)",
                protocolName: "OpenAI",
                stream: false,
                hasContinuationToken: false,
                messages: [.init(role: .user, content: "turn-\(i)")],
                tools: []
            ))
        }

        let recent = meter.recent(limit: 200)
        XCTAssertEqual(recent.count, 120)
        XCTAssertEqual(recent.first?.model, "measurement-20")
        XCTAssertEqual(recent.last?.model, "measurement-139")
    }
}
