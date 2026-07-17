import XCTest
@testable import LingShuMac

@MainActor
final class InterfaceLocalizationTests: XCTestCase {
    func testEnglishRuntimeStatusesDoNotLeakSystemChinese() {
        let state = LingShuState()
        state.language = .english

        XCTAssertEqual(state.localizedRuntimeText("收音待机", fallback: "Audio input idle"), "Audio input idle")
        XCTAssertEqual(state.localizedRuntimeText("视觉权限未授权", fallback: "Vision unavailable"), "Camera access not granted")
        XCTAssertEqual(state.localizedRuntimeText("本地解析 12", fallback: "Perception ready"), "Local analysis 12")
        XCTAssertEqual(state.localizedRuntimeText("尚未登记的新状态", fallback: "Status unavailable"), "Status unavailable")
        XCTAssertFalse(containsHan(state.localizedRuntimeText("尚未登记的新状态", fallback: "Status unavailable")))
    }

    func testUnknownUserContentIsPreservedWithoutSystemFallback() {
        let state = LingShuState()
        state.language = .english

        XCTAssertEqual(state.localizedRuntimeText("用户用中文写下的任务目标"), "用户用中文写下的任务目标")
    }

    func testEnglishConfigurationDescriptorsAreLocalized() {
        let values = [
            LingShuVoiceTranscriptionProviderDescriptor.appleSpeech.localizedDisplayName(language: .english),
            LingShuVoiceTranscriptionProviderDescriptor.appleSpeech.localizedDeployment(language: .english),
            LingShuVoiceTranscriptionProviderDescriptor.appleSpeech.localizedNote(language: .english),
            LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS.localizedDisplayName(language: .english),
            LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS.localizedDeployment(language: .english),
            LingShuSpeechOutputProviderDescriptor.dataNetSpeakerTTS.localizedNote(language: .english),
            LingShuSpeechPersona.calmJarvisMale.localizedDisplayName(language: .english),
            LingShuExpertProfileRegistry.engineer.localizedTitle(language: .english),
            LingShuExpertProfileRegistry.engineer.localizedMission(language: .english),
            LingShuPerceptionRoute.local.localizedDisplayName(language: .english)
        ]

        XCTAssertTrue(values.allSatisfy { !containsHan($0) }, values.joined(separator: "\n"))
    }

    func testTopBarSwitchesBeforeLabelsCanWrap() {
        XCTAssertEqual(LingShuTopBarLayoutPolicy.resolve(for: 1600), .init(dense: false, compact: false))
        XCTAssertEqual(LingShuTopBarLayoutPolicy.resolve(for: 1499), .init(dense: true, compact: false))
        XCTAssertEqual(LingShuTopBarLayoutPolicy.resolve(for: 1299), .init(dense: true, compact: true))
        XCTAssertEqual(LingShuTopBarLayoutPolicy.resolve(for: 900), .init(dense: true, compact: true))
        XCTAssertEqual(PerceptionDotStatus.displayTitle("Owner", compact: true), "O")
        XCTAssertEqual(PerceptionDotStatus.displayTitle("Owner", compact: false), "Owner")
    }

    func testModelLanguageInstructionMatchesInterfaceLanguage() {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: LingShuLanguagePreferenceStore.languageKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: LingShuLanguagePreferenceStore.languageKey) }
            else { defaults.removeObject(forKey: LingShuLanguagePreferenceStore.languageKey) }
        }

        defaults.set(LingShuVoiceLanguage.english.rawValue, forKey: LingShuLanguagePreferenceStore.languageKey)
        XCTAssertTrue(LingShuLanguagePreferenceStore.highestPriorityModelInstruction().hasPrefix("ANSWER IN ENGLISH."))

        defaults.set(LingShuVoiceLanguage.chinese.rawValue, forKey: LingShuLanguagePreferenceStore.languageKey)
        XCTAssertTrue(LingShuLanguagePreferenceStore.highestPriorityModelInstruction().hasPrefix("请用中文沟通和回答。"))
    }

    func testModelPromptStartsWithExactlyOneCurrentLanguageInstruction() {
        let suiteName = "cn.lingshu.tests.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let chineseInstruction = LingShuLanguagePreferenceStore.highestPriorityModelInstruction(for: .chinese)
        let englishInstruction = LingShuLanguagePreferenceStore.highestPriorityModelInstruction(for: .english)
        let reusedPrompt = "\(chineseInstruction)\n\n内部工作流说明。\n\n\(englishInstruction)"

        defaults.set(LingShuVoiceLanguage.english.rawValue, forKey: LingShuLanguagePreferenceStore.languageKey)
        let englishPrompt = LingShuLanguagePreferenceStore.modelPrompt(
            applyingHighestPriorityLanguageTo: reusedPrompt,
            in: defaults
        )
        XCTAssertTrue(englishPrompt.hasPrefix(englishInstruction))
        XCTAssertEqual(englishPrompt.components(separatedBy: englishInstruction).count - 1, 1)
        XCTAssertFalse(englishPrompt.contains(chineseInstruction))
        XCTAssertTrue(englishPrompt.contains("内部工作流说明。"))

        defaults.set(LingShuVoiceLanguage.chinese.rawValue, forKey: LingShuLanguagePreferenceStore.languageKey)
        let chinesePrompt = LingShuLanguagePreferenceStore.modelPrompt(
            applyingHighestPriorityLanguageTo: englishPrompt,
            in: defaults
        )
        XCTAssertTrue(chinesePrompt.hasPrefix(chineseInstruction))
        XCTAssertEqual(chinesePrompt.components(separatedBy: chineseInstruction).count - 1, 1)
        XCTAssertFalse(chinesePrompt.contains(englishInstruction))
    }

    func testEnglishPluginAndPermissionEventLabelsDoNotLeakChinese() {
        let plugin = LingShuInvocablePlugin(
            id: "present",
            displayName: "演示与答疑",
            aliases: [],
            subtitle: "演示文件",
            icon: "play.rectangle"
        )
        XCTAssertEqual(plugin.localizedDisplayName(language: .english), "Presentation & Q&A")

        let state = LingShuState()
        state.language = .english
        let event = state.localizedEventLogItem("现在  执行权限切换为沙箱权限。")
        XCTAssertEqual(event, "Now  Execution permission changed to Sandbox.")
        XCTAssertFalse(containsHan(event))
    }

    func testDirectWebSearchModelPathUsesLanguageInstructionFirst() {
        let english = LingShuState.openRouterWebSearchMessages("current AI news", language: .english)
        XCTAssertEqual(english.first?["role"], "system")
        XCTAssertTrue(english.first?["content"]?.hasPrefix("ANSWER IN ENGLISH.") == true)
        XCTAssertFalse(containsHan(english[1]["content"] ?? ""))

        let chinese = LingShuState.openRouterWebSearchMessages("人工智能新闻", language: .chinese)
        XCTAssertEqual(chinese.first?["role"], "system")
        XCTAssertTrue(chinese.first?["content"]?.hasPrefix("请用中文沟通和回答。") == true)
    }

    private func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
