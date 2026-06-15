import Foundation

/// edit_file 的**多策略匹配级联**(移植自 opencode 的 replacer cascade,借鉴点 #1)。
///
/// 单一精确匹配对模型"缩进/空白稍有出入"很脆 → 编码时常"找不到 old_string"被打回。这里从严到松依次尝试,
/// 直到某一策略给出 content 里**唯一**的匹配片段:
///   精确 → 逐行去空白 → 块锚点(首尾行锚 + 中段 Levenshtein 相似度) → 空白归一 → 缩进灵活。
/// `isDisproportionate` 防"锚点匹配吞掉过大一段"(逼模型重读给准)。纯函数、可单测、无外部依赖。
enum LingShuEditReplacer {
    enum Outcome: Equatable {
        case replaced(String)     // 替换后的新全文
        case identical            // old == new
        case emptyOld             // old 为空(应走 write_file)
        case notFound             // 任何策略都没命中
        case multiple             // 命中但不唯一
        case disproportionate     // 匹配片段比 old 大太多,拒绝
    }

    private static let similarityThreshold = 0.65

    static func replace(content: String, oldString: String, newString: String) -> Outcome {
        if oldString == newString { return .identical }
        if oldString.isEmpty { return .emptyOld }
        var foundAny = false
        let replacers: [(String, String) -> [String]] = [
            simpleCandidates, lineTrimmedCandidates, blockAnchorCandidates,
            whitespaceNormalizedCandidates, indentationFlexibleCandidates
        ]
        for replacer in replacers {
            for search in replacer(content, oldString) where !search.isEmpty {
                guard let first = content.range(of: search) else { continue }
                foundAny = true
                if isDisproportionate(search: search, oldString: oldString) { return .disproportionate }
                let last = content.range(of: search, options: .backwards)
                if first != last { continue }   // 不唯一 → 试下一个候选/策略
                var result = content
                result.replaceSubrange(first, with: newString)
                return .replaced(result)
            }
        }
        return foundAny ? .multiple : .notFound
    }

    // MARK: - 策略(每个产出 content 的候选子串)

    private static func simpleCandidates(_ content: String, _ find: String) -> [String] { [find] }

    /// 逐行去首尾空白后比对——容忍模型把缩进/行尾空白写错。
    private static func lineTrimmedCandidates(_ content: String, _ find: String) -> [String] {
        let original = content.components(separatedBy: "\n")
        var search = find.components(separatedBy: "\n")
        if search.last == "" { search.removeLast() }
        guard !search.isEmpty, original.count >= search.count else { return [] }
        var out: [String] = []
        for i in 0...(original.count - search.count) {
            var matches = true
            for j in 0..<search.count where trimmed(original[i + j]) != trimmed(search[j]) { matches = false; break }
            if matches { out.append(original[i..<(i + search.count)].joined(separator: "\n")) }
        }
        return out
    }

    /// 块锚点:首尾行作锚定位候选块(容忍块大小 ±25%),中段用 Levenshtein 相似度(≥0.65)裁决。
    /// 适合"大段里只改了中间几行"——首尾对得上就锚定,不要求中间逐字符一致。
    private static func blockAnchorCandidates(_ content: String, _ find: String) -> [String] {
        let original = content.components(separatedBy: "\n")
        var search = find.components(separatedBy: "\n")
        guard search.count >= 3 else { return [] }
        if search.last == "" { search.removeLast() }
        guard !search.isEmpty else { return [] }
        let firstSearch = trimmed(search[0])
        let lastSearch = trimmed(search[search.count - 1])
        let blockSize = search.count
        let maxDelta = max(1, blockSize / 4)

        var candidates: [(start: Int, end: Int)] = []
        for i in 0..<original.count where trimmed(original[i]) == firstSearch {
            var j = i + 2
            while j < original.count {
                if trimmed(original[j]) == lastSearch {
                    if abs((j - i + 1) - blockSize) <= maxDelta { candidates.append((i, j)) }
                    break
                }
                j += 1
            }
        }
        guard !candidates.isEmpty else { return [] }

        func extract(_ s: Int, _ e: Int) -> String { original[s...e].joined(separator: "\n") }
        func middleSimilarity(_ start: Int, _ actualSize: Int, average: Bool) -> Double {
            let linesToCheck = min(blockSize - 2, actualSize - 2)
            guard linesToCheck > 0 else { return 1.0 }
            var similarity = 0.0
            var j = 1
            while j < blockSize - 1 && j < actualSize - 1 {
                let o = trimmed(original[start + j]); let s = trimmed(search[j])
                let maxLen = max(o.count, s.count)
                if maxLen != 0 {
                    let sim = 1 - Double(levenshtein(o, s)) / Double(maxLen)
                    similarity += average ? sim : sim / Double(linesToCheck)
                    if !average && similarity >= similarityThreshold { break }
                }
                j += 1
            }
            return average ? similarity / Double(linesToCheck) : similarity
        }

        if candidates.count == 1 {
            let c = candidates[0]
            let sim = middleSimilarity(c.start, c.end - c.start + 1, average: false)
            return sim >= similarityThreshold ? [extract(c.start, c.end)] : []
        }
        var best: (start: Int, end: Int)?
        var maxSim = -1.0
        for c in candidates {
            let sim = middleSimilarity(c.start, c.end - c.start + 1, average: true)
            if sim > maxSim { maxSim = sim; best = c }
        }
        if maxSim >= similarityThreshold, let b = best { return [extract(b.start, b.end)] }
        return []
    }

    /// 空白归一:把连续空白压成一个空格再比(整行 / 行内子串 / 多行块)。
    private static func whitespaceNormalizedCandidates(_ content: String, _ find: String) -> [String] {
        let normalizedFind = normalizeWhitespace(find)
        var out: [String] = []
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if normalizeWhitespace(line) == normalizedFind {
                out.append(line)
            } else if normalizeWhitespace(line).contains(normalizedFind) {
                let words = trimmed(find).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
                if !words.isEmpty {
                    let pattern = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
                    if let re = try? NSRegularExpression(pattern: pattern),
                       let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                       let r = Range(m.range, in: line) {
                        out.append(String(line[r]))
                    }
                }
            }
        }
        let findLines = find.components(separatedBy: "\n")
        if findLines.count > 1, lines.count >= findLines.count {
            for i in 0...(lines.count - findLines.count) {
                let block = lines[i..<(i + findLines.count)].joined(separator: "\n")
                if normalizeWhitespace(block) == normalizedFind { out.append(block) }
            }
        }
        return out
    }

    /// 缩进灵活:对 find 和候选块都剥掉"公共最小缩进"再比——容忍整体缩进层级不同。
    private static func indentationFlexibleCandidates(_ content: String, _ find: String) -> [String] {
        let normalizedFind = removeCommonIndent(find)
        let contentLines = content.components(separatedBy: "\n")
        let findLines = find.components(separatedBy: "\n")
        guard !findLines.isEmpty, contentLines.count >= findLines.count else { return [] }
        var out: [String] = []
        for i in 0...(contentLines.count - findLines.count) {
            let block = contentLines[i..<(i + findLines.count)].joined(separator: "\n")
            if removeCommonIndent(block) == normalizedFind { out.append(block) }
        }
        return out
    }

    // MARK: - 工具

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func normalizeWhitespace(_ t: String) -> String {
        trimmed(t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
    }

    private static func leadingWhitespaceCount(_ s: String) -> Int {
        var n = 0
        for c in s { if c == " " || c == "\t" { n += 1 } else { break } }
        return n
    }

    private static func removeCommonIndent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !trimmed($0).isEmpty }
        guard !nonEmpty.isEmpty else { return text }
        let minIndent = nonEmpty.map { leadingWhitespaceCount($0) }.min() ?? 0
        return lines.map { trimmed($0).isEmpty ? $0 : String($0.dropFirst(minIndent)) }.joined(separator: "\n")
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        if ac.isEmpty || bc.isEmpty { return max(ac.count, bc.count) }
        var prev = Array(0...bc.count)
        var curr = [Int](repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            curr[0] = i
            for j in 1...bc.count {
                let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bc.count]
    }

    /// 匹配片段是否比 old 大太多(防块锚点等吞掉一大段误改)。
    static func isDisproportionate(search: String, oldString: String) -> Bool {
        let oldLines = oldString.components(separatedBy: "\n").count
        let searchLines = search.components(separatedBy: "\n").count
        if searchLines >= max(oldLines + 3, oldLines * 2) { return true }
        if oldLines == 1 { return false }
        let st = trimmed(search).count
        let ot = trimmed(oldString).count
        return st > max(ot + 500, ot * 4)
    }
}
