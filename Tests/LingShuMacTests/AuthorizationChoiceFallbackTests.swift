import XCTest
@testable import LingShuMac

@MainActor
final class AuthorizationChoiceFallbackTests: XCTestCase {
    func testOAuthMarkerRendersRedactedAuthorizationCardEvenWithIntermediateArtifact() throws {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "配置一个外部模型通道")
        let artifactURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-auth-intermediate-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: artifactURL)
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        // Keep the runtime shape realistic without committing a scanner-triggering token literal.
        let secret = "sk-" + "SUPERSECRET-abc1234567890"
        state.bindGoalSpec(.init(objective: "配置外部模型通道", kind: .task), to: recordID)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(
                kind: .humanConfirmation,
                missing: "保存 API Token \(secret) 并连接外部服务",
                fillPath: "用户确认后写入本地加密凭据库。",
                blocking: true
            )
        ], note: "等待用户确认", OAuth: .init(
            required: true,
            target: "外部模型通道",
            action: "保存 API Token 并连接外部服务",
            reason: "需要用户确认敏感凭据操作。",
            question: "是否允许保存 API Token \(secret) 并连接外部服务？"
        )), to: recordID)
        try "{}".write(to: artifactURL, atomically: true, encoding: .utf8)
        state.appendTaskRecordArtifact(
            recordID,
            title: artifactURL.lastPathComponent,
            location: artifactURL.path,
            producer: "测试"
        )

        let block = state.userAuthorizationBlockIfNeeded(
            decision: .init(status: .waitingForUser, reason: "需要用户确认敏感凭据操作"),
            result: .completed(text: "等待确认"),
            taskRecordID: recordID
        )

        guard case .blocked(let raw) = block,
              let envelope = LingShuHumanInputEnvelope.decode(from: raw) else {
            return XCTFail("明确的 OAuth 标识即使已有中间产物也必须生成授权选择卡")
        }
        XCTAssertEqual(envelope.tool, "ask_choice")
        let parsed = LingShuState.parseChoiceArgs(envelope.argumentsJSON)
        XCTAssertTrue(parsed.1.contains { $0.label.contains("确认授权") })
        XCTAssertFalse(parsed.0.contains(secret), "授权卡不得回显完整凭据")
        XCTAssertTrue(parsed.0.contains("***"), "凭据应以脱敏形式呈现")
        XCTAssertFalse(state.capabilityUserAsk(taskRecordID: recordID).contains(secret))
    }

    func testBlockingUserGapWithoutOAuthMarkerDoesNotRenderAuthorizationCard() {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "配置一个外部模型通道")
        defer {
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        state.bindGoalSpec(.init(objective: "配置外部模型通道", kind: .task), to: recordID)
        state.bindGapAnalysis(.init(feasibleNow: false, gaps: [
            .init(
                kind: .humanConfirmation,
                missing: "需要用户确认后继续",
                fillPath: "等待用户输入。",
                blocking: true
            )
        ], note: "等待用户确认", OAuth: nil), to: recordID)

        let block = state.userAuthorizationBlockIfNeeded(
            decision: .init(status: .waitingForUser, reason: "需要用户确认"),
            result: .completed(text: "请确认后继续"),
            taskRecordID: recordID
        )

        XCTAssertNil(block, "没有 OAuth/auth 标识时，普通阻塞项不得生成授权选择卡")
    }

    func testIntermediateArtifactDoesNotBypassSuppressionForNonAuthPrompt() throws {
        let state = LingShuState()
        let recordID = state.createTaskExecutionRecord(for: "生成一份报告")
        let artifactURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingshu-non-auth-artifact-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: artifactURL)
            state.taskExecutionRecords.removeAll { $0.id == recordID }
            state.persistTaskExecutionRecords()
            state.taskExecutionJournal.flush()
        }

        try "已生成".write(to: artifactURL, atomically: true, encoding: .utf8)
        state.appendTaskRecordArtifact(
            recordID,
            title: artifactURL.lastPathComponent,
            location: artifactURL.path,
            producer: "测试"
        )
        let result = #"{"reply":"还需要补充说明","completion":{"status":"waiting_for_user","reason":"请补充报告口径","needs_user":true},"OAuth":null}"#

        XCTAssertNil(
            state.userPrerequisiteChoicePromptIfNeeded(resultText: result, taskRecordID: recordID),
            "中间产物只对明确 OAuth 授权卡放行，不应改变普通前提卡的原有判断"
        )
    }
}
