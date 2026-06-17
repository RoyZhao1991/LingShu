import Foundation

/// 国际化(目前中/英两档)。语音语言(VoiceIOManager.voiceLanguage)决定:
/// ASR 识别 locale、TTS 嗓音语种(英文走本机英文嗓),以及**灵枢的回复语言**——
/// 选英文则全程英文(含 speak 出声),否则中文。这条规则注入各系统提示词(主/自主)。
@MainActor
extension LingShuState {
    func languageResponseRule() -> String {
        (voiceManager?.voiceLanguage ?? .chinese) == .english
            ? "【Language — highest priority】The user selected **English**. Respond in English for ALL replies and spoken output (including the `speak` tool), regardless of the language of these instructions."
            : "直接用中文简洁作答。"
    }
}
