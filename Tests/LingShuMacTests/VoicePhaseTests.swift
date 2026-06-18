import XCTest
@testable import LingShuMac

/// 语音状态机闭环单测(用户定调 2026-06-18):待机→我在听→处理中→回应中→待机,
/// 变体:处理中/回应中被唤醒词打断→我在听;我在听无有效内容→待机。
final class VoicePhaseTests: XCTestCase {
    private let window: TimeInterval = 6

    private func derive(
        audible: Bool = false,
        busy: Bool = false,
        ttsPending: Bool = false,
        armed: Bool = false,
        sinceActivity: TimeInterval = 999
    ) -> LingShuVoicePhase {
        LingShuVoicePhase.derive(
            audiblePlaying: audible,
            modelOrLoopBusy: busy,
            ttsQueuedOrPending: ttsPending,
            listeningArmed: armed,
            secondsSinceVoiceActivity: sinceActivity,
            listeningWindow: window
        )
    }

    // MARK: - 主闭环 待机→我在听→处理中→回应中→待机

    func testStandbyWhenIdle() {
        XCTAssertEqual(derive(), .standby)
    }

    func testListeningWhenArmedWithinWindow() {
        XCTAssertEqual(derive(armed: true, sinceActivity: 1), .listening)
    }

    func testProcessingWhenModelBusy() {
        XCTAssertEqual(derive(busy: true, armed: true, sinceActivity: 1), .processing,
                       "提交后模型在跑:处理中优先于我在听")
    }

    func testProcessingWhenTTSPendingButNotAudibleYet() {
        XCTAssertEqual(derive(ttsPending: true), .processing, "TTS 已请求还没起播 → 处理中")
    }

    func testRespondingWhenAudioPlaying() {
        XCTAssertEqual(derive(audible: true, busy: true, ttsPending: true), .responding,
                       "音频真在播 → 回应中,优先级最高")
    }

    func testBackToStandbyAfterPlaybackEnds() {
        // 播放结束:音频停、模型不忙、聆听窗口已超时 → 待机(不再卡处理中)
        XCTAssertEqual(derive(audible: false, busy: false, ttsPending: false, armed: false), .standby)
    }

    // MARK: - 变体

    func testWakeInterruptDuringResponseGoesToListening() {
        // 唤醒词打断:先掐 TTS(audible/ttsPending 归 false)+ 开聆听窗口 → 我在听
        XCTAssertEqual(derive(audible: false, busy: false, ttsPending: false, armed: true, sinceActivity: 0),
                       .listening)
    }

    func testListeningFallsBackToStandbyAfterWindowExpires() {
        // 我在听窗口内没有效内容(超时)→ 待机
        XCTAssertEqual(derive(armed: true, sinceActivity: window + 0.1), .standby)
    }

    func testListeningStaysWithinWindowBoundary() {
        XCTAssertEqual(derive(armed: true, sinceActivity: window - 0.1), .listening)
    }
}
