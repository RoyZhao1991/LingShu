import XCTest
@testable import LingShuMac

/// 会议检测 + 转写分段拼装的纯逻辑测试(脱网、确定性)。
final class MeetingMinutesTests: XCTestCase {

    func testDetectsMeetingAppByBundle() {
        XCTAssertTrue(LingShuMeetingDetector.looksLikeMeetingApp("us.zoom.xos"))
        XCTAssertTrue(LingShuMeetingDetector.looksLikeMeetingApp("com.tencent.wemeet"))
        XCTAssertTrue(LingShuMeetingDetector.looksLikeMeetingApp("com.microsoft.teams2"))
        XCTAssertFalse(LingShuMeetingDetector.looksLikeMeetingApp("com.apple.Safari"))
        XCTAssertFalse(LingShuMeetingDetector.looksLikeMeetingApp(nil))
    }

    func testDetectsMeetingByWindowTitle() {
        XCTAssertTrue(LingShuMeetingDetector.titleLooksLikeMeeting("Chrome · Google Meet - 项目周会"))
        XCTAssertTrue(LingShuMeetingDetector.titleLooksLikeMeeting("腾讯会议 正在通话"))
        XCTAssertFalse(LingShuMeetingDetector.titleLooksLikeMeeting("Xcode — LingShuState.swift"))
    }

    func testEnterAndExitTransitions() {
        var s = LingShuMeetingDetectionState()
        let t0 = Date()
        // 进入:Zoom 前台
        XCTAssertEqual(LingShuMeetingDetector.update(&s, frontmostBundle: "us.zoom.xos", windowSignature: "Zoom Meeting", audioActive: true, now: t0), .entered)
        XCTAssertTrue(s.inMeeting)
        // 切去记笔记(前台变 Notes),但会议还有声音 → 仍在会议
        XCTAssertEqual(LingShuMeetingDetector.update(&s, frontmostBundle: "com.apple.Notes", windowSignature: "Notes", audioActive: true, now: t0.addingTimeInterval(20)), .none)
        XCTAssertTrue(s.inMeeting)
        // 会议结束:无会议界面、无声音,超过 grace(60s)→ 离开
        XCTAssertEqual(LingShuMeetingDetector.update(&s, frontmostBundle: "com.apple.Notes", windowSignature: "Notes", audioActive: false, now: t0.addingTimeInterval(20 + 61)), .exited)
        XCTAssertFalse(s.inMeeting)
    }

    func testNoExitWithinGrace() {
        var s = LingShuMeetingDetectionState()
        let t0 = Date()
        _ = LingShuMeetingDetector.update(&s, frontmostBundle: "us.zoom.xos", windowSignature: "Zoom", audioActive: true, now: t0)
        // 切走 + 没声音,但还没到 grace → 不离开
        XCTAssertEqual(LingShuMeetingDetector.update(&s, frontmostBundle: "com.apple.Safari", windowSignature: "Safari", audioActive: false, now: t0.addingTimeInterval(30)), .none)
        XCTAssertTrue(s.inMeeting)
    }

    func testDoesNotEnterOnNonMeeting() {
        var s = LingShuMeetingDetectionState()
        XCTAssertEqual(LingShuMeetingDetector.update(&s, frontmostBundle: "com.apple.Safari", windowSignature: "新闻", audioActive: true), .none)
        XCTAssertFalse(s.inMeeting)
    }

    func testAssembleTranscriptWithRelativeMinutes() {
        let base = Date()
        let segs = [
            LingShuMeetingMinuteSegment(at: base, text: "大家好,开始开会"),
            LingShuMeetingMinuteSegment(at: base.addingTimeInterval(120), text: "讨论第二个议题")
        ]
        let text = LingShuMeetingDetector.assembleTranscript(segs, start: base)
        XCTAssertTrue(text.contains("[0分] 大家好"))
        XCTAssertTrue(text.contains("[2分] 讨论第二个议题"))
    }

    func testAssembleEmpty() {
        XCTAssertEqual(LingShuMeetingDetector.assembleTranscript([], start: nil), "")
    }
}
