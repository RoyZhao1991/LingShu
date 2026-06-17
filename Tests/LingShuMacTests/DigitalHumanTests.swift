import XCTest
@testable import LingShuMac

final class DigitalHumanTests: XCTestCase {

    func testExpressionParsingAcceptsChineseAndEnglishAliases() {
        XCTAssertEqual(LingShuDigitalHumanExpression.parse("presenting"), .presenting)
        XCTAssertEqual(LingShuDigitalHumanExpression.parse("演示"), .presenting)
        XCTAssertEqual(LingShuDigitalHumanExpression.parse("说话"), .speaking)
        XCTAssertEqual(LingShuDigitalHumanExpression.parse("警戒"), .alert)
    }

    func testReceivingInputStateIsGreen() {
        // 自主运行「接收输入」态:绿色 +「我在听」。
        XCTAssertEqual(LingShuDigitalHumanExpression.receiving.displayName, "我在听")
        XCTAssertEqual(LingShuDigitalHumanExpression.receiving.accent, .green)
        XCTAssertEqual(LingShuDigitalHumanExpression.parse("接收输入"), .receiving)
        XCTAssertEqual(LingShuDigitalHumanExpression.parse("我在听"), .receiving)
    }

    @MainActor
    func testDirectiveDrivesDigitalHumanSnapshot() {
        let state = LingShuState()
        let voice = VoiceIOManager()
        let vision = VisionIOManager()
        let gateway = LingShuRealtimePerceptionGateway()

        state.setDigitalHumanExpression(.presenting, message: "开始汇报", durationSeconds: 5)
        let snapshot = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: gateway)

        XCTAssertEqual(snapshot.expression, .presenting)
        XCTAssertEqual(snapshot.displayText, "开始汇报")
        XCTAssertTrue(snapshot.isDirectiveDriven)
    }

    @MainActor
    func testExpiredDirectiveFallsBackToLiveState() {
        let state = LingShuState()
        let voice = VoiceIOManager()
        let vision = VisionIOManager()
        let gateway = LingShuRealtimePerceptionGateway()
        state.digitalHumanDirective = .init(
            expression: .alert,
            message: "旧告警",
            source: "测试",
            intensity: 1,
            issuedAt: Date().addingTimeInterval(-20),
            expiresAt: Date().addingTimeInterval(-1)
        )

        let snapshot = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: gateway)

        XCTAssertEqual(snapshot.expression, .standby)
        XCTAssertFalse(snapshot.isDirectiveDriven)
    }

    @MainActor
    func testSpeakingWithoutAudibleOutputDoesNotActivateMouth() {
        let state = LingShuState()
        let voice = VoiceIOManager()
        let vision = VisionIOManager()
        let gateway = LingShuRealtimePerceptionGateway()

        voice.isSpeaking = true
        voice.outputLevel = 0
        let snapshot = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: gateway)
        voice.isSpeaking = false

        XCTAssertFalse(snapshot.signalIsActive(.mouth))
        XCTAssertNotEqual(snapshot.expression, .speaking)
    }

    @MainActor
    func testAudibleOutputActivatesMouthAndSpeakingExpression() {
        let state = LingShuState()
        let voice = VoiceIOManager()
        let vision = VisionIOManager()
        let gateway = LingShuRealtimePerceptionGateway()

        voice.outputLevel = 0.42
        let snapshot = state.digitalHumanSnapshot(voice: voice, vision: vision, perceptionGateway: gateway)

        XCTAssertTrue(snapshot.signalIsActive(.mouth))
        XCTAssertEqual(snapshot.expression, .speaking)
        XCTAssertGreaterThan(snapshot.intensity, LingShuDigitalHumanExpression.speaking.baseIntensity)
    }
}
