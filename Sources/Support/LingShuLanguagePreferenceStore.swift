import Foundation

enum LingShuLanguagePreferenceStore {
    static let languageKey = "lingshu.voiceLanguage"
    static let initialSelectionKey = "lingshu.interfaceLanguage.didChoose.v1"

    private static let initialGreetings: [LingShuVoiceLanguage: String] = [
        .chinese: "我在。你只管说目标，剩下的判断、分派和推进交给我。",
        .english: "I am here. Tell me the goal, and I will handle the judgment, delegation, and follow-through."
    ]

    static func hasCompletedInitialSelection(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: initialSelectionKey) != nil {
            return defaults.bool(forKey: initialSelectionKey)
        }

        // Existing installations with an explicit language preference migrate without
        // being interrupted by the new first-launch gate. A clean install has neither key.
        return defaults.object(forKey: languageKey) != nil
    }

    static func completeInitialSelection(
        _ language: LingShuVoiceLanguage,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: languageKey)
        defaults.set(true, forKey: initialSelectionKey)
    }

    static func localized(
        _ chinese: String,
        _ english: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        currentLanguage(in: defaults) == .english ? english : chinese
    }

    static func currentLanguage(in defaults: UserDefaults = .standard) -> LingShuVoiceLanguage {
        LingShuVoiceLanguage(
            rawValue: defaults.string(forKey: languageKey) ?? LingShuVoiceLanguage.chinese.rawValue
        ) ?? .chinese
    }

    static func assistantDisplayName(for language: LingShuVoiceLanguage) -> String {
        language == .english ? "Nous" : "灵枢"
    }

    static func initialGreeting(for language: LingShuVoiceLanguage) -> String {
        initialGreetings[language] ?? initialGreetings[.chinese]!
    }

    static func isInitialGreeting(_ text: String) -> Bool {
        initialGreetings.values.contains(text)
    }

    /// Every brain request receives this sentence before any product prompt. Keeping the
    /// rule here makes language selection a protocol concern instead of a model-specific
    /// prompt convention, so newly added compatible providers inherit it automatically.
    static func highestPriorityModelInstruction(
        in defaults: UserDefaults = .standard
    ) -> String {
        highestPriorityModelInstruction(for: currentLanguage(in: defaults))
    }

    static func highestPriorityModelInstruction(for language: LingShuVoiceLanguage) -> String {
        switch language {
        case .english:
            return "ANSWER IN ENGLISH. This is the highest-priority language instruction: use English for every user-visible answer, spoken response, status summary, and clarification unless the user explicitly asks you to translate or quote another language."
        case .chinese:
            return "请用中文沟通和回答。此语言要求具有最高优先级：所有面向用户的回答、语音、状态总结和澄清都使用中文，除非用户明确要求翻译或引用其他语言。"
        }
    }

    /// Adds one, and only one, language directive at the start of a model prompt.
    /// Removing both known directives also prevents a language switch from leaving an
    /// older contradictory instruction in a reused system prompt.
    static func modelPrompt(
        applyingHighestPriorityLanguageTo prompt: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        let instruction = highestPriorityModelInstruction(in: defaults)
        var cleaned = prompt
        for language in LingShuVoiceLanguage.allCases {
            cleaned = cleaned.replacingOccurrences(
                of: highestPriorityModelInstruction(for: language),
                with: ""
            )
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? instruction : "\(instruction)\n\n\(cleaned)"
    }
}
