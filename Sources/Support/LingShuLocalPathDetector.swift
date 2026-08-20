import Foundation

enum LingShuLocalPathDetector {
    struct Match: Equatable {
        let path: String
        let range: Range<String.Index>
    }

    struct Presentation: Equatable, Sendable {
        let displayText: String
        let paths: [String]
    }

    private static let localPathPattern = #"(?<![A-Za-z0-9_~.-])(/[^\n\r]+?\.[A-Za-z0-9][A-Za-z0-9_-]{0,15})(?=$|[^A-Za-z0-9_./-])"#
    private static let regexStore = RegexStore()

    private final class RegexStore: @unchecked Sendable {
        let localPath = try? NSRegularExpression(pattern: localPathPattern)
        let emptyMarkdownWrapper = try? NSRegularExpression(pattern: "(`{1,3})\\s*\\1")
        let danglingSeparator = try? NSRegularExpression(pattern: "\\s*[:：]\\s*[`'\"“”‘’\\s]*[—–-]\\s*")
        let repeatedWhitespace = try? NSRegularExpression(pattern: "\\s{2,}")
    }

    nonisolated static func existingFilePaths(
        in text: String,
        fileExists: (String) -> Bool = LingShuLocalPathDetector.isExistingRegularFile
    ) -> [String] {
        existingFilePathMatches(in: text, fileExists: fileExists).map(\.path)
    }

    nonisolated static func displayTextHidingExistingFilePaths(
        in text: String,
        fileExists: (String) -> Bool = LingShuLocalPathDetector.isExistingRegularFile
    ) -> String {
        presentation(in: text, fileExists: fileExists).displayText
    }

    /// Resolves preview paths and the human-readable line in one pass. Message rendering used to
    /// run the same regex and `fileExists` checks twice for every table cell and every body line.
    nonisolated static func presentation(
        in text: String,
        fileExists: (String) -> Bool = LingShuLocalPathDetector.isExistingRegularFile
    ) -> Presentation {
        let matches = existingFilePathMatches(in: text, fileExists: fileExists)
        guard !matches.isEmpty else { return Presentation(displayText: text, paths: []) }
        var output = ""
        var cursor = text.startIndex
        for match in matches {
            let removalRange = expandedMarkdownWrapperRange(around: match.range, in: text)
            output += text[cursor..<removalRange.lowerBound]
            cursor = removalRange.upperBound
        }
        output += text[cursor..<text.endIndex]
        return Presentation(
            displayText: cleanHiddenPathText(output),
            paths: matches.map(\.path)
        )
    }

    nonisolated static func existingFilePathMatches(
        in text: String,
        fileExists: (String) -> Bool = LingShuLocalPathDetector.isExistingRegularFile
    ) -> [Match] {
        guard text.contains("/"), let regex = regexStore.localPath else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var matches: [Match] = []
        for match in regex.matches(in: text, range: nsRange) {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            let path = normalize(String(text[range]))
            guard !seen.contains(path), fileExists(path) else { continue }
            seen.insert(path)
            matches.append(.init(path: path, range: range))
        }
        return matches
    }

    private nonisolated static func cleanHiddenPathText(_ raw: String) -> String {
        replacing(regexStore.repeatedWhitespace, in:
            replacing(regexStore.danglingSeparator, in:
                replacing(regexStore.emptyMarkdownWrapper, in: raw, with: ""),
                with: "："
            ),
            with: " "
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func replacing(
        _ regex: NSRegularExpression?,
        in text: String,
        with template: String
    ) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }

    private nonisolated static func expandedMarkdownWrapperRange(
        around range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            guard "`\"'“”‘’<".contains(text[previous]) else { break }
            lower = previous
        }
        while upper < text.endIndex {
            guard "`\"'“”‘’>".contains(text[upper]) else { break }
            upper = text.index(after: upper)
        }
        return lower..<upper
    }

    private nonisolated static func normalize(_ raw: String) -> String {
        let unescaped = raw.replacingOccurrences(of: #"\\ "#, with: " ", options: .regularExpression)
        return (unescaped.removingPercentEncoding ?? unescaped)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’<>"))
    }

    private nonisolated static func isExistingRegularFile(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
