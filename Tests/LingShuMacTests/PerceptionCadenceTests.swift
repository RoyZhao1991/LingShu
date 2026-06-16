import XCTest
@testable import LingShuMac

/// 模块 2 周期感知循环纯逻辑测试：节流决策 + 音频突变分类。脱网确定性。
final class PerceptionCadenceTests: XCTestCase {

    // MARK: - 音频突变检测（滞回）

    func testAudioDetectorSilenceToOnsetToActiveToOffset() {
        var detector = LingShuAudioActivityDetector(onThreshold: 0.02, offThreshold: 0.008)
        XCTAssertEqual(detector.ingest(level: 0.001), .silent)   // 安静
        XCTAssertEqual(detector.ingest(level: 0.05), .onset)     // 突变上行 = 起音
        XCTAssertEqual(detector.ingest(level: 0.04), .active)    // 持续有声
        XCTAssertEqual(detector.ingest(level: 0.012), .active)   // 滞回区间内仍算有声（高于 off 阈值）
        XCTAssertEqual(detector.ingest(level: 0.001), .offset)   // 跌破 off 阈值 = 落音
        XCTAssertEqual(detector.ingest(level: 0.001), .silent)   // 回到安静
    }

    func testAudioDetectorHysteresisAvoidsFlapping() {
        // 电平在 off 与 on 阈值之间抖动时，不应反复 onset/offset。
        var detector = LingShuAudioActivityDetector(onThreshold: 0.02, offThreshold: 0.008)
        _ = detector.ingest(level: 0.05)                          // 进入 active
        XCTAssertEqual(detector.ingest(level: 0.015), .active)    // 在滞回带内（>off, <on）：保持 active，不落音
        XCTAssertEqual(detector.ingest(level: 0.015), .active)
        XCTAssertTrue(detector.isActive)
    }

    // MARK: - 节流 planner

    private func input(
        now: TimeInterval,
        lastTick: TimeInterval = 0,
        lastVL: TimeInterval = 0,
        lastWake: TimeInterval = 0,
        screenChanged: Bool = false,
        audio: LingShuAudioActivityState? = nil,
        agentBusy: Bool = false,
        autoReactArmed: Bool = false
    ) -> LingShuPerceptionTickInput {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        return .init(
            now: base.addingTimeInterval(now),
            lastTickAt: base.addingTimeInterval(lastTick),
            lastVLAt: base.addingTimeInterval(lastVL),
            lastWakeAt: base.addingTimeInterval(lastWake),
            screenChanged: screenChanged,
            audio: audio,
            agentBusy: agentBusy,
            autoReactArmed: autoReactArmed
        )
    }

    func testNotDueBeforeTickInterval() {
        let decision = LingShuPerceptionCadencePlanner.decide(input(now: 2, lastTick: 0))
        XCTAssertFalse(decision.due)
        XCTAssertFalse(decision.captureVL)
        XCTAssertFalse(decision.wakeAgent)
    }

    func testAgentBusyYieldsNoCaptureNoWake() {
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 100, lastTick: 0, lastVL: 0, screenChanged: true, audio: .onset, agentBusy: true, autoReactArmed: true)
        )
        XCTAssertTrue(decision.due)
        XCTAssertFalse(decision.captureVL)   // 大脑在跑 → 让位，不重复 VL
        XCTAssertFalse(decision.wakeAgent)
    }

    func testScreenChangedPastMinIntervalCapturesVL() {
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 20, lastTick: 0, lastVL: 0, screenChanged: true)
        )
        XCTAssertTrue(decision.captureVL)
    }

    func testScreenChangedWithinMinIntervalSkipsVL() {
        // 屏幕变了，但距上次 VL 仅 5s（< minVLInterval 9s）→ 成本天花板压住，不 VL。
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 5, lastTick: 0, lastVL: 0, screenChanged: true)
        )
        XCTAssertTrue(decision.due)
        XCTAssertFalse(decision.captureVL)
    }

    func testNoChangeButForcedRefreshCapturesVL() {
        // 屏幕签名没变，但距上次 VL 已 50s（> forcedVLInterval 45s）→ 强制刷新抓动态内容。
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 50, lastTick: 40, lastVL: 0, screenChanged: false)
        )
        XCTAssertTrue(decision.captureVL)
    }

    func testNoChangeWithinForcedIntervalSkipsVL() {
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 20, lastTick: 10, lastVL: 0, screenChanged: false)
        )
        XCTAssertTrue(decision.due)
        XCTAssertFalse(decision.captureVL)
    }

    func testAudioOnsetArmedPastCooldownWakesAgent() {
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 60, lastTick: 0, lastWake: 0, audio: .onset, autoReactArmed: true)
        )
        XCTAssertTrue(decision.wakeAgent)
        XCTAssertNotNil(decision.wakeReason)
    }

    func testAudioOnsetNotArmedDoesNotWake() {
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 60, lastTick: 0, lastWake: 0, audio: .onset, autoReactArmed: false)
        )
        XCTAssertFalse(decision.wakeAgent)
    }

    func testAudioOnsetWithinCooldownDoesNotWake() {
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 20, lastTick: 0, lastWake: 10, audio: .onset, autoReactArmed: true)
        )
        XCTAssertFalse(decision.wakeAgent)
    }

    func testScreenChangedArmedPastCooldownWakesAgent() {
        // 前台/界面变化(无音频)在武装+过冷却时也唤醒大脑——感知是输入,大脑综合评判,不只认音频。
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 60, lastTick: 0, lastWake: 0, screenChanged: true, audio: nil, autoReactArmed: true)
        )
        XCTAssertTrue(decision.wakeAgent)
        XCTAssertNotNil(decision.wakeReason)
    }

    func testScreenChangedNotArmedDoesNotWake() {
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 60, lastTick: 0, lastWake: 0, screenChanged: true, audio: nil, autoReactArmed: false)
        )
        XCTAssertFalse(decision.wakeAgent)
    }

    func testActiveAudioDoesNotWakeOnlyOnsetDoes() {
        // 持续有声（active）不算事件，只有起音（onset）才唤醒——避免一直响就一直唤醒。
        let decision = LingShuPerceptionCadencePlanner.decide(
            input(now: 60, lastTick: 0, lastWake: 0, audio: .active, autoReactArmed: true)
        )
        XCTAssertFalse(decision.wakeAgent)
    }
}
