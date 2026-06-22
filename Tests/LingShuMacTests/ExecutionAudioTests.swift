import XCTest
@testable import LingShuMac

/// 执行音三态决策守卫(用户定调:卡授权→急促高音断音催授权,与执行忙音**隔离、不并发**)。
final class ExecutionAudioTests: XCTestCase {

    func testStuckAtAuthAlwaysAuthAlertNeverBusy() {
        // 卡授权界面时:无论是否处理中/朗读,一律授权告警——绝不和忙音并发。
        XCTAssertEqual(LingShuCueSound.executionAudioDecision(stuckAtAuth: true, processing: true, isSpeaking: false), .authAlert)
        XCTAssertEqual(LingShuCueSound.executionAudioDecision(stuckAtAuth: true, processing: false, isSpeaking: false), .authAlert)
        XCTAssertEqual(LingShuCueSound.executionAudioDecision(stuckAtAuth: true, processing: true, isSpeaking: true), .authAlert)
    }

    func testProcessingNotSpeakingIsBusy() {
        XCTAssertEqual(LingShuCueSound.executionAudioDecision(stuckAtAuth: false, processing: true, isSpeaking: false), .busy)
    }

    func testSpeakingSuppressesBusy() {
        XCTAssertEqual(LingShuCueSound.executionAudioDecision(stuckAtAuth: false, processing: true, isSpeaking: true), .silent)
    }

    func testIdleIsSilent() {
        XCTAssertEqual(LingShuCueSound.executionAudioDecision(stuckAtAuth: false, processing: false, isSpeaking: false), .silent)
    }

    func testMutualExclusion_authAndBusyNeverCoexist() {
        // 穷举:任一组合下,authAlert 与 busy 互斥(不可能同时;授权恒优先)。
        for auth in [true, false] {
            for proc in [true, false] {
                for spk in [true, false] {
                    let d = LingShuCueSound.executionAudioDecision(stuckAtAuth: auth, processing: proc, isSpeaking: spk)
                    if auth { XCTAssertEqual(d, .authAlert, "卡授权必为告警") }
                    else { XCTAssertNotEqual(d, .authAlert, "未卡授权绝不出告警") }
                }
            }
        }
    }
}
