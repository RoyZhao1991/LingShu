import Foundation

/// 只用于 TTS 的展示元信息清洗。
///
/// 界面仍然可以显示「总用时」这类运行信息,但它不是自然回复内容,
/// 进入语音合成前必须剥掉,避免灵枢把 UI 尾注读出来。
enum LingShuSpeechDisplayMetadata {
    static func stripping(_ text: String) -> String {
        var cleaned = text
        let elapsedLinePattern = #"(?m)^\s*(?:⏱\s*)?总用时\s*[0-9０-９]+(?:\.[0-9]+)?\s*(?:秒|s|S)?\s*$"#
        let trailingElapsedPattern = #"\s*(?:⏱\s*)?总用时\s*[0-9０-９]+(?:\.[0-9]+)?\s*(?:秒|s|S)?\s*$"#

        cleaned = cleaned.replacingOccurrences(of: elapsedLinePattern, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: trailingElapsedPattern, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
