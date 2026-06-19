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

    // MARK: - 自适应收口窗口(2026-06-19 修"喊灵枢没说完就进处理中")

    func testSilenceHoldGivesLongWindowBeforeSubstantiveCommand() {
        // 刚喊完唤醒词、几乎没说实质内容(speechTicks 少)→ 用长窗口(5s)等主人开口。
        let hold = LingShuVoiceCallController.silenceHold(speechTicks: 3, substantiveThreshold: 12, initialHold: 5.0, afterCommandHold: 3.0)
        XCTAssertEqual(hold, 5.0)
    }

    func testSilenceHoldShortensAfterSubstantiveCommand() {
        // 已说出实质指令(speechTicks 过阈值)→ 命令结束后用短窗口(3s)收口。
        let hold = LingShuVoiceCallController.silenceHold(speechTicks: 20, substantiveThreshold: 12, initialHold: 5.0, afterCommandHold: 3.0)
        XCTAssertEqual(hold, 3.0)
        // 恰好到阈值也算"已说实质指令"。
        XCTAssertEqual(LingShuVoiceCallController.silenceHold(speechTicks: 12, substantiveThreshold: 12, initialHold: 5.0, afterCommandHold: 3.0), 3.0)
    }

    // MARK: - 转写收口判据(2026-06-19 修"喊灵枢说指令像没听到":嘈杂下指令永不收口)

    func testFinalizeOnTranscriptStability() {
        let now = Date()
        // ASR partial 静默超阈值 → 收口(干净环境的快路)。
        XCTAssertTrue(VoiceIOManager.shouldFinalizeUtterance(
            now: now, lastPartialAt: now.addingTimeInterval(-2.5), transcriptStableSeconds: 2.0,
            lastLoudInputAt: now.addingTimeInterval(-0.5), audioQuietSeconds: 3.0))
    }

    func testFinalizeOnAudioSilenceEvenWhenPartialsChurn() {
        let now = Date()
        // 噪音持续刷新 partial(lastPartialAt 很新),但主人已停止出声超阈值 → 仍收口(兜底,不被噪音拖住)。
        XCTAssertTrue(VoiceIOManager.shouldFinalizeUtterance(
            now: now, lastPartialAt: now.addingTimeInterval(-0.3), transcriptStableSeconds: 2.0,
            lastLoudInputAt: now.addingTimeInterval(-3.2), audioQuietSeconds: 3.0))
    }

    func testDoesNotFinalizeWhileStillTalking() {
        let now = Date()
        // partial 在长、且主人还在出声(刚出声)→ 不收口(别打断还在说的人)。
        XCTAssertFalse(VoiceIOManager.shouldFinalizeUtterance(
            now: now, lastPartialAt: now.addingTimeInterval(-0.3), transcriptStableSeconds: 2.0,
            lastLoudInputAt: now.addingTimeInterval(-0.4), audioQuietSeconds: 3.0))
    }

    // MARK: - 口语化清洗(2026-06-19:自主模式只能听,朗读前剥 markdown/emoji/破折号)

    @MainActor func testOralizeStripsMarkdownEmojiAndDash() {
        let out = VoiceIOManager.strippedForSpeech("**文件与代码**——读写文件 ✅\n📍 当前天气 🌡️ 64°F\n要点1、要点2")
        XCTAssertFalse(out.contains("**"))        // markdown 强调符剥掉
        XCTAssertFalse(out.contains("——"))        // 破折号转停顿
        XCTAssertFalse(out.contains("✅"))         // 装饰 emoji 剥掉
        XCTAssertFalse(out.contains("📍"))
        XCTAssertFalse(out.contains("🌡"))
        XCTAssertTrue(out.contains("文件与代码"))   // 正文内容保留
        XCTAssertTrue(out.contains("要点1"))        // ASCII 数字保留(不被 emoji 阈值误伤)
        XCTAssertTrue(out.contains("64"))
    }

    @MainActor func testOralizeDropsCodeBlocksAndTables() {
        let out = VoiceIOManager.strippedForSpeech("讲解开始\n```\ncode line\n```\n| 列A | 列B |\n正文继续")
        XCTAssertFalse(out.contains("code line"))   // 代码块不念
        XCTAssertFalse(out.contains("列A"))          // 表格行不念
        XCTAssertTrue(out.contains("讲解开始"))
        XCTAssertTrue(out.contains("正文继续"))
    }
}
