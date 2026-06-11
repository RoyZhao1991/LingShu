import XCTest
@testable import LingShuMac

final class VoiceAddressingGateTests: XCTestCase {
    private func inputs(
        wakeWord: Bool = false,
        lock: Bool = false,
        confidence: Double? = nil,
        multiSpeaker: Bool = false,
        sinceExchange: TimeInterval? = nil,
        callMode: Bool = false
    ) -> LingShuVoiceAddressingGate.Inputs {
        .init(
            transcript: "测试语句",
            containsWakeWord: wakeWord,
            lockEnabled: lock,
            ownerVoiceConfidence: confidence,
            multipleSpeakersDetected: multiSpeaker,
            secondsSinceLastExchange: sinceExchange,
            isExplicitCallMode: callMode
        )
    }

    func testLockEnabledRejectsMismatchedVoiceEvenWithWakeWord() {
        // 主人声线优先：旁人喊"灵枢"也不放行
        let verdict = LingShuVoiceAddressingGate.decide(inputs(wakeWord: true, lock: true, confidence: 0.3))
        guard case .ignore(let reason) = verdict else { return XCTFail("应忽略") }
        XCTAssertTrue(reason.contains("声线与主人档案不匹配"))
    }

    func testLockEnabledAcceptsOwnerVoice() {
        let verdict = LingShuVoiceAddressingGate.decide(inputs(lock: true, confidence: 0.8, callMode: true))
        guard case .respond = verdict else { return XCTFail("主人声线应放行") }
    }

    func testWakeWordRespondsInNoisyMultiSpeakerRoom() {
        let verdict = LingShuVoiceAddressingGate.decide(inputs(wakeWord: true, multiSpeaker: true, sinceExchange: 600))
        XCTAssertEqual(verdict, .respond(reason: "点名灵枢"))
    }

    func testMultiSpeakerWithoutWakeWordAndStaleExchangeIgnores() {
        // 多人交谈、没点名、很久没和灵枢说话 → 判定人际交谈，不插话
        let verdict = LingShuVoiceAddressingGate.decide(inputs(multiSpeaker: true, sinceExchange: 300))
        guard case .ignore(let reason) = verdict else { return XCTFail("应忽略") }
        XCTAssertTrue(reason.contains("人际交谈"))
    }

    func testMultiSpeakerWithinEngagementWindowResponds() {
        let verdict = LingShuVoiceAddressingGate.decide(inputs(multiSpeaker: true, sinceExchange: 20))
        guard case .respond = verdict else { return XCTFail("对话延续中应响应") }
    }

    func testSingleSpeakerCallModeResponds() {
        let verdict = LingShuVoiceAddressingGate.decide(inputs(callMode: true))
        XCTAssertEqual(verdict, .respond(reason: "通话模式"))
    }

    func testAdaptiveVADRaisesThresholdsInNoise() {
        var vad = LingShuAdaptiveVAD()
        let quietSpeak = vad.speakThreshold
        XCTAssertEqual(quietSpeak, 0.12, accuracy: 0.01, "安静环境用基准阈值")

        // 持续 0.08 的底噪（风扇/人声嘈杂）
        for _ in 0..<200 {
            vad.observe(level: 0.08, isCapturingSpeech: false)
        }
        XCTAssertGreaterThan(vad.speakThreshold, quietSpeak, "嘈杂环境应抬高说话阈值")
        XCTAssertGreaterThan(vad.silenceThreshold, 0.06, "收口阈值应随底噪抬升")
        XCTAssertLessThan(vad.silenceThreshold, vad.speakThreshold, "收口阈值必须低于说话阈值")
        XCTAssertGreaterThanOrEqual(vad.bargeInThreshold, vad.speakThreshold, "打断阈值最高")
    }

    func testAdaptiveVADDoesNotLearnWhileSpeaking() {
        var vad = LingShuAdaptiveVAD()
        let before = vad.noiseFloor
        for _ in 0..<50 {
            vad.observe(level: 0.4, isCapturingSpeech: true)
        }
        XCTAssertEqual(vad.noiseFloor, before, "说话中的电平不能被当成噪声底")
    }

    func testProfilerDetectsTwoSpeakers() {
        let profiler = LingShuSpeakerProfiler()
        func sine(_ frequency: Double) -> LingShuAudioStreamPacket {
            let sampleRate = 16000.0
            let frames = Int(sampleRate * 0.25)
            var data = Data(capacity: frames * 2)
            for index in 0..<frames {
                var sample = Int16(max(-32768, min(32767, 0.4 * sin(2 * .pi * frequency * Double(index) / sampleRate) * 32767))).littleEndian
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            }
            return .init(timestamp: Date(), pcm16Data: data, sampleRate: sampleRate, channelCount: 1, frameCount: frames)
        }
        for _ in 0..<8 {
            profiler.ingest(sine(120))
            profiler.ingest(sine(225))
        }
        XCTAssertTrue(profiler.multipleSpeakersSuspected, "120Hz 与 225Hz 双簇应判定为多说话人")

        let single = LingShuSpeakerProfiler()
        for _ in 0..<16 { single.ingest(sine(120)) }
        XCTAssertFalse(single.multipleSpeakersSuspected)
    }
}
