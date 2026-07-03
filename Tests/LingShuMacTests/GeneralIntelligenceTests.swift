import XCTest
@testable import LingShuMac

final class SpeakerProfilerTests: XCTestCase {
    /// 生成指定基频的正弦波 PCM16 数据包。
    private func sinePacket(frequency: Double, sampleRate: Double = 16000, duration: Double = 0.25, amplitude: Double = 0.4) -> LingShuAudioStreamPacket {
        let frameCount = Int(sampleRate * duration)
        var data = Data(capacity: frameCount * 2)
        for index in 0..<frameCount {
            let value = amplitude * sin(2 * .pi * frequency * Double(index) / sampleRate)
            var sample = Int16(max(-32768, min(32767, value * 32767))).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return .init(timestamp: Date(), pcm16Data: data, sampleRate: sampleRate, channelCount: 1, frameCount: frameCount)
    }

    func testPitchEstimationOnSyntheticTones() {
        let male = LingShuSpeakerProfiler.estimatePitch(
            pcm16Data: sinePacket(frequency: 120).pcm16Data, sampleRate: 16000, channelCount: 1
        )
        XCTAssertNotNil(male)
        XCTAssertEqual(male!, 120, accuracy: 8, "120Hz 正弦波的基频估计应接近 120")

        let female = LingShuSpeakerProfiler.estimatePitch(
            pcm16Data: sinePacket(frequency: 220).pcm16Data, sampleRate: 16000, channelCount: 1
        )
        XCTAssertNotNil(female)
        XCTAssertEqual(female!, 220, accuracy: 12)
    }

    func testSilenceProducesNoPitch() {
        let silent = LingShuSpeakerProfiler.estimatePitch(
            pcm16Data: sinePacket(frequency: 120, amplitude: 0.001).pcm16Data, sampleRate: 16000, channelCount: 1
        )
        XCTAssertNil(silent, "静音段不应产出基频，避免污染画像")
    }

    func testGenderClassificationFromRollingPitch() {
        let profiler = LingShuSpeakerProfiler()
        for _ in 0..<12 {
            profiler.ingest(sinePacket(frequency: 118))
        }
        let snapshot = profiler.snapshot()
        XCTAssertEqual(snapshot?.genderLabel, "男声")
        XCTAssertNotNil(snapshot?.promptLine)

        let female = LingShuSpeakerProfiler.classify(medianPitch: 215, sampleCount: 24)
        XCTAssertEqual(female.gender, "女声")
        XCTAssertEqual(female.confidence, "高")

        let ambiguous = LingShuSpeakerProfiler.classify(medianPitch: 170, sampleCount: 30)
        XCTAssertTrue(ambiguous.gender.hasPrefix("未定"))
    }
}

final class SituationContextTests: XCTestCase {
    func testDaySegments() {
        XCTAssertEqual(LingShuSituationContext.daySegment(hour: 2), "深夜")
        XCTAssertEqual(LingShuSituationContext.daySegment(hour: 6), "清晨")
        XCTAssertEqual(LingShuSituationContext.daySegment(hour: 15), "下午")
        XCTAssertEqual(LingShuSituationContext.daySegment(hour: 23), "深夜")
    }

    func testComposeCarriesTimeTaskAndSpeaker() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: 23, minute: 40))!
        let context = LingShuSituationContext.compose(.init(
            now: now,
            calendar: calendar,
            sessionStartedAt: now.addingTimeInterval(-2 * 3600),
            speakerLine: "说话人声线：基频约 210Hz，推测为女声（置信度中）。",
            visionSummary: "光线正常，检测到 1 张人脸",
            activeTaskTitle: "杭州PPT",
            activeTaskStage: "评审中"
        ))
        XCTAssertTrue(context.contains("23:40"))
        XCTAssertTrue(context.contains("深夜"))
        XCTAssertTrue(context.contains("2.0 小时"))
        XCTAssertTrue(context.contains("女声"))
        XCTAssertTrue(context.contains("杭州PPT"))
        XCTAssertTrue(context.contains("评审中"))
    }
}

final class TaskAdmissionTests: XCTestCase {
    func testBusyPipelineQueues() {
        let verdict = LingShuTaskAdmissionPolicy.evaluate(.init(cpuLoadPerCore: 0.3, freeMemoryRatio: 0.5, activePipelines: 1))
        XCTAssertEqual(verdict.decision, .queue)
        XCTAssertTrue(verdict.reason.contains("队列"))
    }

    func testHighCPUQueues() {
        let verdict = LingShuTaskAdmissionPolicy.evaluate(.init(cpuLoadPerCore: 2.4, freeMemoryRatio: 0.5, activePipelines: 0))
        XCTAssertEqual(verdict.decision, .queue)
        XCTAssertTrue(verdict.reason.contains("CPU"))
    }

    func testLowMemoryQueues() {
        let verdict = LingShuTaskAdmissionPolicy.evaluate(.init(cpuLoadPerCore: 0.2, freeMemoryRatio: 0.03, activePipelines: 0))
        XCTAssertEqual(verdict.decision, .queue)
        XCTAssertTrue(verdict.reason.contains("内存"))
    }

    func testHealthySystemProceeds() {
        let verdict = LingShuTaskAdmissionPolicy.evaluate(.init(cpuLoadPerCore: 0.4, freeMemoryRatio: 0.4, activePipelines: 0))
        XCTAssertEqual(verdict.decision, .proceed)
    }

    func testRealProbeReturnsSaneValues() {
        let sample = LingShuSystemLoadProbe.currentSample(activePipelines: 0)
        XCTAssertGreaterThanOrEqual(sample.freeMemoryRatio, 0)
        XCTAssertLessThanOrEqual(sample.freeMemoryRatio, 1)
        XCTAssertGreaterThanOrEqual(sample.cpuLoadPerCore, 0)
    }
}

final class ExpertProfileRegistryTests: XCTestCase {
    private let registry = LingShuExpertProfileRegistry()

    func testDefaultProfileDoesNotKeywordRouteTaskText() {
        // 默认注册表不再用关键词把自然语言硬派给专家;角色选择由主脑结合能力图谱/GoalSpec 在规划阶段判断。
        for text in ["做一个高可用的系统架构设计", "写一份产品需求文档 PRD", "给这个项目做项目分析和排期", "做一个介绍杭州的PPT", "写一个爬虫脚本"] {
            XCTAssertEqual(registry.profile(for: text).id, "expert-engineer")
        }
    }

    func testEveryProfileHasTemplateKnowledgeAndChecklist() {
        for profile in registry.allProfiles where profile.id != "expert-reviewer" {
            XCTAssertFalse(profile.deliverableTemplate.isEmpty, "\(profile.title) 缺模板")
            XCTAssertFalse(profile.knowledgeHighlights.isEmpty, "\(profile.title) 缺知识要点")
            XCTAssertFalse(profile.reviewChecklist.isEmpty, "\(profile.title) 缺评审清单")
            XCTAssertTrue(profile.promptBlock.contains(profile.title))
        }
        XCTAssertEqual(registry.reviewerProfile().id, "expert-reviewer")
    }
}

final class SituationComponentTests: XCTestCase {
    private struct FireComponent: LingShuSituationComponent {
        func contribute(_ inputs: LingShuSituationContext.Inputs) -> String? { "检测到明火，疑似起火。" }
    }

    func testNewDimensionPlugsInWithoutTouchingCompose() {
        // 新增态势维度只要加一个组件——验证"组件拼装"可扩展。
        let inputs = LingShuSituationContext.Inputs(now: Date())
        let composed = LingShuSituationContext.compose(
            inputs,
            components: LingShuSituationContext.defaultComponents + [FireComponent()]
        )
        XCTAssertTrue(composed.contains("疑似起火"), "新组件的事实应被拼进【当前情境】")
        XCTAssertTrue(composed.hasPrefix("【当前情境】"))
    }

    func testComponentsThatDontApplyAreOmitted() {
        // 没有 session/视觉/任务 → 只剩时间一句，其余组件返回 nil 被略过。
        let composed = LingShuSituationContext.compose(.init(now: Date()))
        XCTAssertTrue(composed.contains("本机时间"))
        XCTAssertFalse(composed.contains("连续使用"))
        XCTAssertFalse(composed.contains("摄像头画面"))
    }
}
