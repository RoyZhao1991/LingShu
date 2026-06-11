import Foundation

/// 过滤 Codex CLI 的内部诊断日志，避免把底层 retry/trace 噪声混进用户对话。
/// 内部诊断只进执行记录或调试窗（见 ARCHITECTURE.md Infrastructure 规则 4）。
enum CodexDiagnosticLogFilter {
    private static let diagnosticLevels = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"]

    static func userVisibleText(from rawText: String) -> String {
        rawText
            .components(separatedBy: .newlines)
            .filter { !isInternalDiagnosticLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isInternalDiagnosticLine(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }

        let lowercased = line.lowercased()
        if lowercased.contains("codex_core::responses_retry")
            || lowercased.contains("stream disconnected - retrying sampling request") {
            return true
        }

        guard line.count > 28,
              line[line.startIndex...].contains("codex_") else {
            return false
        }

        let hasTimestampPrefix = line.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#,
            options: .regularExpression
        ) != nil
        guard hasTimestampPrefix else { return false }

        return diagnosticLevels.contains { level in
            line.contains(" \(level) codex_")
        }
    }

    static func diagnosticLines(from rawText: String) -> [String] {
        rawText
            .components(separatedBy: .newlines)
            .filter(isInternalDiagnosticLine)
    }

    static func diagnosticSummary(from rawText: String) -> String {
        let diagnostics = diagnosticLines(from: rawText)
        guard !diagnostics.isEmpty else {
            return rawText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return diagnostics
            .suffix(3)
            .joined(separator: "\n")
    }
}
