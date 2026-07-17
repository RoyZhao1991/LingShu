import XCTest
@testable import LingShuCLIKit
@testable import LingShuMac

final class CLIControlTests: XCTestCase {
    func testContinuationPrefersNewestMessageFromSameTaskRecord() {
        let messages: [[String: Any]] = [
            ["id": "old", "text": "Scan the code", "isUser": false, "taskRecordID": "record-1"],
            ["id": "new", "text": "Setup completed", "isUser": false, "taskRecordID": "record-1"]
        ]

        let original = LingShuCLIClient.selectAssistantMessage(
            from: messages,
            assistantMessageID: "old",
            recordID: "record-1"
        )
        XCTAssertEqual(original?["id"] as? String, "old")

        let resumed = LingShuCLIClient.selectAssistantMessage(
            from: messages,
            assistantMessageID: "old",
            recordID: "record-1",
            preferLatestRecordMessage: true
        )
        XCTAssertEqual(resumed?["id"] as? String, "new")
    }

    func testCLIConfigurationUsesLoopbackDefaultsAndEnvironmentOverrides() {
        let defaults = LingShuCLIConfiguration.environment([:])
        XCTAssertEqual(defaults.endpoint.absoluteString, "http://127.0.0.1:8917/mcp")
        XCTAssertTrue(defaults.autoLaunchApp)

        let custom = LingShuCLIConfiguration.environment([
            "LINGSHU_MCP_PORT": "9901",
            "LINGSHU_MCP_TOKEN": "local-token",
            "LINGSHU_CLI_TIMEOUT": "42",
            "LINGSHU_CLI_NO_LAUNCH": "1"
        ])
        XCTAssertEqual(custom.endpoint.absoluteString, "http://127.0.0.1:9901/mcp")
        XCTAssertEqual(custom.token, "local-token")
        XCTAssertEqual(custom.timeout, 42)
        XCTAssertFalse(custom.autoLaunchApp)
    }

    func testCLIRecognizesCanonicalAndLegacyTaskCompletion() {
        let canonical = LingShuCLIClient.taskCompletion(from: [
            "status": "已直接回答",
            "isTerminal": true,
            "isSuccessful": true
        ])
        XCTAssertEqual(canonical?.isTerminal, true)
        XCTAssertEqual(canonical?.isSuccessful, true)

        let legacySuccess = LingShuCLIClient.taskCompletion(from: ["status": "已直接回答"])
        XCTAssertEqual(legacySuccess?.isTerminal, true)
        XCTAssertEqual(legacySuccess?.isSuccessful, true)

        let legacyFailure = LingShuCLIClient.taskCompletion(from: ["status": "未达标"])
        XCTAssertEqual(legacyFailure?.isTerminal, true)
        XCTAssertEqual(legacyFailure?.isSuccessful, false)

        XCTAssertNil(LingShuCLIClient.taskCompletion(from: ["status": "执行中"]))
    }

    func testCachedTaskDetailCarriesCanonicalCompletionState() throws {
        let now = Date()
        let record = LingShuTaskExecutionRecord(
            id: "cli-completed-record",
            title: "CLI check",
            prompt: "Reply CLI_OK",
            status: .answered,
            summary: "CLI_OK",
            participants: ["You", "LingShu"],
            createdAt: now,
            updatedAt: now,
            messages: []
        )
        LingShuControlSnapshotStore.shared.update(
            status: [:],
            records: [record],
            feedback: [:],
            chat: [],
            trace: []
        )

        let text = try XCTUnwrap(LingShuControlSnapshotStore.shared.cachedToolText(
            name: "lingshu_task_detail",
            arguments: ["recordId": record.id]
        ))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["isTerminal"] as? Bool, true)
        XCTAssertEqual(payload["isSuccessful"] as? Bool, true)
        XCTAssertEqual(payload["isResumable"] as? Bool, false)
    }

    @MainActor
    func testControlChatPayloadCarriesCompleteHumanInteractionMaterial() {
        let state = LingShuState()
        let request = LingShuHumanInteractionRequest(
            id: "scan-login",
            kind: .qrCode,
            title: "Scan to sign in",
            prompt: "Scan this QR code in WeChat.",
            materials: [
                .init(kind: .qrCode, title: "WeChat", value: "https://example.com/login/qr")
            ],
            completionProbe: .init(kind: .httpStatus, target: "http://127.0.0.1:18011/health", expectedStatus: 200)
        )
        state.chatMessages.append(.init(
            speaker: "LingShu",
            text: request.prompt,
            isUser: false,
            taskRecordID: "record-1",
            humanInteraction: request
        ))

        let payload = LingShuControlRouter(state: state).chatPayload(limit: 1)
        let interaction = payload.first?["humanInteraction"] as? [String: Any]
        XCTAssertEqual(interaction?["id"] as? String, "scan-login")
        XCTAssertEqual(interaction?["kind"] as? String, "qr_code")
        let materials = interaction?["materials"] as? [[String: Any]]
        XCTAssertEqual(materials?.first?["kind"] as? String, "qr_code")
        XCTAssertEqual(materials?.first?["value"] as? String, "https://example.com/login/qr")
        let probe = interaction?["completionProbe"] as? [String: Any]
        XCTAssertEqual(probe?["kind"] as? String, "http_status")
    }

    @MainActor
    func testExternalHumanInteractionSubmissionResumesExactMessage() {
        let state = LingShuState()
        let request = LingShuHumanInteractionRequest(
            id: "physical-step",
            kind: .physicalAction,
            title: "Connect device",
            prompt: "Connect the cable and continue."
        )
        let message = ChatMessage(
            speaker: "LingShu",
            text: request.prompt,
            isUser: false,
            humanInteraction: request
        )
        state.chatMessages.append(message)
        state.pendingHumanInteractionContexts[message.id] = .init(
            request: request,
            inputContext: .init(recordID: nil, originalPrompt: "Set up the device")
        )

        let response = LingShuControlRouter(state: state).submitExternalHumanInteraction([
            "messageId": message.id.uuidString,
            "answer": "Connected"
        ])

        XCTAssertFalse(response.isError)
        XCTAssertNil(state.pendingHumanInteractionContexts[message.id])
        XCTAssertNil(state.chatMessages.first(where: { $0.id == message.id })?.humanInteraction)
    }
}
