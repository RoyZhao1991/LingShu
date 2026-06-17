import Foundation

/// 国际化(中/英两档)。`LingShuState.language` 是全局唯一语言开关:切它则**整个界面 + 状态 + 本体**动态切语言,
/// 并同步语音子系统(ASR locale / TTS 嗓音 / 灵枢回复语言)。视图都观察 state,故切语言时全 UI 自动重渲染。
/// 视图里用 `state.loc("中文", "English")` 取当前语言文案;灵枢英文名 = Nous(用户定名 2026-06-17)。
@MainActor
extension LingShuState {

    /// 取当前语言的文案:`state.loc(中文, English)`。
    func loc(_ zh: String, _ en: String) -> String { language == .english ? en : zh }

    /// 灵枢的对外名字(英文界面叫 Nous;Nous=古希腊「心智/灵慧」,即「灵慧之中枢」)。
    var appName: String { language == .english ? "Nous" : "灵枢" }

    /// 注入系统提示词的回复语言规则:选英文则全程英文(含 speak),否则中文。
    func languageResponseRule() -> String {
        language == .english
            ? "【Language — highest priority】The user selected **English**. Respond in English for ALL replies and spoken output (including the `speak` tool), regardless of the language of these instructions."
            : "直接用中文简洁作答。"
    }
}

// MARK: - 界面枚举的英文映射(中文 rawValue 已是显示名,这里补英文)

extension AppSurface {
    var englishName: String {
        switch self {
        case .chat: "Chat"
        case .taskPool: "Threads"
        case .runtime: "Status"
        case .operations: "Ops"
        case .settings: "Settings"
        }
    }
}

extension LingShuCoreState {
    var englishName: String {
        switch self {
        case .standby: "Standby"
        case .thinking: "Thinking"
        case .executing: "Executing"
        case .abnormal: "Abnormal"
        }
    }
}

extension LingShuLoopPhase {
    var englishName: String {
        switch self {
        case .idle: ""
        case .understanding: "Understanding"
        case .planning: "Planning"
        case .executing: "Executing"
        case .verifying: "Verifying"
        }
    }
}
