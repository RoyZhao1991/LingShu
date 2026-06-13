import Foundation

/// 评审的逐条核对结论：从评审官输出里解析 ✅/❌ 行与最终结论。
/// checklist 驱动的循环判定——"全部通过才算过"，让"完成"二字有分量。
struct LingShuChecklistVerdict: Equatable {
    let passedCount: Int
    let failedCount: Int
    /// 评审官明确写了「结论：通过」。
    let declaredPass: Bool

    /// 既要明确判过、又不能有未达标项，才算真通过。
    var allPassed: Bool {
        declaredPass && failedCount == 0
    }

    var summaryLine: String {
        if allPassed {
            return "逐条核对：\(passedCount) 项全部达标 ✅ 结论：通过"
        }
        return "逐条核对：\(passedCount) 达标 / \(failedCount) 未达标 ❌ 结论：需修正"
    }

    static func parse(_ text: String) -> LingShuChecklistVerdict {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        // 明确判过：写了「结论：通过」且没写「需修正」。
        let declaredPass = (normalized.contains("结论：通过") || normalized.contains("结论:通过"))
            && !normalized.contains("需修正")

        // 优先用结构化统计行 `PASS=N FAIL=M`——可靠，不受逐条标记位置、说明里勾叉的干扰。
        // （评审官把标记写在加粗标题后、或正文里夹杂 ✅/❌ 时，行首计数会数成 0，统计行根治这个。）
        if let pass = firstInt(in: text, pattern: "PASS\\s*=\\s*(\\d+)"),
           let fail = firstInt(in: text, pattern: "FAIL\\s*=\\s*(\\d+)") {
            return .init(passedCount: pass, failedCount: fail, declaredPass: declaredPass)
        }

        // 兜底：模型没给统计行时，数行首 ✅/❌。
        var passed = 0
        var failed = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("✅") { passed += 1 }
            else if line.hasPrefix("❌") { failed += 1 }
        }
        return .init(passedCount: passed, failedCount: failed, declaredPass: declaredPass)
    }

    private static func firstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}
