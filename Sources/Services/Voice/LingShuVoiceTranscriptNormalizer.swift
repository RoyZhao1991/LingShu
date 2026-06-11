import Foundation

enum LingShuVoiceTranscriptNormalizer {
    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let collapsedWhitespace = trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let compactChineseSpacing = collapsedWhitespace
            .replacingOccurrences(
                of: #"(?<=[\p{Han}])\s+(?=[\p{Han}，。！？、；：])"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<=[，。！？、；：])\s+(?=[\p{Han}])"#,
                with: "",
                options: .regularExpression
            )

        return compactChineseSpacing
    }
}

