import XCTest
@testable import LingShuMac

final class SpeechIntentPolicyTests: XCTestCase {
    func testOrdinaryAnalysisAndFileWorkStaySilentByDefault() {
        assertUnspecified("分析一下这个 PDF")
        assertUnspecified("根据附件生成一份 Word 文档")
        assertUnspecified("生成一个演示文稿")
        assertUnspecified("create a presentation about the quarterly plan")
        assertUnspecified("summarize these files")
    }

    func testExplicitChineseNarrationConversationAndPresentationSpeak() {
        assertSpeaks("朗读这份报告")
        assertSpeaks("用语音回答我")
        assertSpeaks("跟我沟通一下这个方案")
        assertSpeaks("我们来聊聊实现思路")
        assertSpeaks("开始演示这个 PPT")
        assertSpeaks("给我演示一下这份方案")
        assertSpeaks("演示这份幻灯片")
    }

    func testExplicitEnglishNarrationConversationAndPresentationSpeak() {
        assertSpeaks("Read it aloud")
        assertSpeaks("Talk to me about this design")
        assertSpeaks("Present this deck")
        assertSpeaks("Walk me through the report")
    }

    func testVoiceAndMeetingInputsSpeakWithoutTextKeyword() {
        XCTAssertEqual(
            LingShuSpeechIntentPolicy.decision(for: "今天怎么样", source: .voice),
            .speak
        )
        XCTAssertEqual(
            LingShuSpeechIntentPolicy.decision(for: "请回答这个问题", source: .meeting),
            .speak
        )
    }

    func testExplicitSilenceOverridesVoiceAndPresentationSignals() {
        XCTAssertEqual(
            LingShuSpeechIntentPolicy.decision(
                for: "演示这个 PPT，但不要读出声，只要文字",
                source: .typed
            ),
            .silent
        )
        XCTAssertEqual(
            LingShuSpeechIntentPolicy.decision(
                for: "Don't speak. Reply in text only.",
                source: .voice
            ),
            .silent
        )
    }

    func testPluginInputDoesNotSpeakWithoutExplicitIntent() {
        XCTAssertEqual(
            LingShuSpeechIntentPolicy.decision(
                for: "整理刚完成的后台任务",
                source: .plugin("scheduler")
            ),
            .unspecified
        )
    }

    private func assertSpeaks(
        _ request: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            LingShuSpeechIntentPolicy.decision(for: request, source: .typed),
            .speak,
            file: file,
            line: line
        )
    }

    private func assertUnspecified(
        _ request: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            LingShuSpeechIntentPolicy.decision(for: request, source: .typed),
            .unspecified,
            file: file,
            line: line
        )
    }
}
