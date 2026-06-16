import Foundation

/// 唤醒词匹配（纯函数，可单测）：ASR 几乎不可能把生僻词"灵枢"两个字都转写对（实测 bug #4「喊灵枢唤不醒」），
/// 死板的 `contains("灵枢")` 注定失败。这里**不靠字面、靠读音**：把识别出来的**任意汉字**转成拼音，
/// 再与唤醒词的拼音做**模糊音**比对——这样无论 ASR 写成 灵书/铃枢/凌树/另书/您输…… 只要读音接近就命中，
/// 不需要手工穷举同音字。模糊音规则取常见南方口音/ASR 混淆:l↔n、-ng↔-n、sh↔s、zh↔z、ch↔c。
enum LingShuWakeWordMatcher {

    /// 仍保留一小撮字面变体作快路/兜底（拼音转换偶尔拿不到时）。主力是下面的拼音模糊匹配。
    static let lingShuVariants: [String] = ["灵枢", "灵书", "铃枢", "凌枢", "灵树"]

    /// 文本是否点名了灵枢（读音匹配 + 字面兜底）。
    static func contains(_ text: String, wakeWord: String) -> Bool {
        let haystack = stripped(text)
        guard !haystack.isEmpty else { return false }
        // ① 字面快路(配置词 + 内建变体)。
        var literals = lingShuVariants
        let configured = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { literals.append(configured) }
        if literals.contains(where: { haystack.contains(stripped($0)) }) { return true }
        // ② 读音模糊匹配:唤醒词的模糊拼音序列,作为子序列出现在文本的模糊拼音序列里即命中。
        let wakeKeys = fuzzyPinyinKeys(configured.isEmpty ? "灵枢" : configured)
        guard !wakeKeys.isEmpty else { return false }
        let textKeys = fuzzyPinyinKeys(text)
        return containsConsecutive(textKeys, wakeKeys)
    }

    /// 剥掉句首的唤醒词，返回真正的指令体（"灵枢，介绍一下你自己" → "介绍一下你自己"）。
    /// 先试字面变体；都不命中再按**读音**剥掉句首与唤醒词同音的那几个字（如"灵书，xxx"→"xxx"）。
    static func stripWakeWord(from text: String, wakeWord: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var literals = lingShuVariants
        let configured = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { literals.append(configured) }
        for needle in literals.sorted(by: { $0.count > $1.count }) {
            if let range = trimmed.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                return tail(of: trimmed, after: range.upperBound)
            }
        }
        // 读音剥离:句首若有 N 个汉字的拼音 = 唤醒词拼音,就把这 N 个字连同其后的标点/空白去掉。
        let wakeKeys = fuzzyPinyinKeys(configured.isEmpty ? "灵枢" : configured)
        guard !wakeKeys.isEmpty else { return trimmed }
        let chars = Array(trimmed)
        var keys: [String] = []
        var consumed = 0
        while consumed < chars.count, keys.count < wakeKeys.count {
            let ch = chars[consumed]
            let chKeys = fuzzyPinyinKeys(String(ch))
            guard chKeys.count == 1, !ch.isASCII else { break }   // 只逐个吃汉字
            keys.append(contentsOf: chKeys)
            consumed += 1
        }
        if keys.count >= wakeKeys.count, Array(keys.prefix(wakeKeys.count)) == wakeKeys {
            let after = trimmed.index(trimmed.startIndex, offsetBy: consumed)
            return tail(of: trimmed, after: after)
        }
        return trimmed
    }

    // MARK: - 拼音 / 模糊音(纯函数)

    /// 文本 → 模糊拼音音节序列（如"灵枢介绍"→ ["lin","su","jie","sao"]）。读音匹配的核心。
    static func fuzzyPinyinKeys(_ text: String) -> [String] {
        guard let latin = text
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) else { return [] }
        return latin.lowercased()
            .split { !$0.isLetter }            // 拼音音节以空格分隔；按非字母切
            .map { fuzzyKey(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// 单个拼音音节归一成「模糊音键」：抹平 ASR/口音常见混淆,让同音近音落到同一个键。
    static func fuzzyKey(_ syllableRaw: String) -> String {
        var s = syllableRaw.lowercased()
        guard !s.isEmpty else { return "" }
        // 声母:翘舌↔平舌(zh/ch/sh → z/c/s)、鼻音边音(n → l)。
        if s.hasPrefix("zh") || s.hasPrefix("ch") || s.hasPrefix("sh") { s.remove(at: s.index(after: s.startIndex)) } // 删第二个字母(h)
        if s.hasPrefix("n") { s = "l" + s.dropFirst() }
        // 韵母:前后鼻音(-ang/-eng/-ing → -an/-en/-in)——删紧跟 a/e/i 之后、且在词尾或辅音前的 g。
        s = collapseNasal(s)
        return s
    }

    /// -ng → -n（前后鼻音不分）：把 "ang/eng/ing/ong" 末尾的 g 去掉(仅当其后不再有元音,避免误伤)。
    private static func collapseNasal(_ s: String) -> String {
        var chars = Array(s)
        var out: [Character] = []
        var i = 0
        let vowels = Set("aeiou")
        while i < chars.count {
            let c = chars[i]
            if c == "g", let prev = out.last, prev == "n" {
                // 仅当 "ng" 后面不再接元音时折叠(rang vs rang+元音的情况极少,这里词尾/辅音前折叠)
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next == nil || !vowels.contains(next!) {
                    i += 1   // 丢掉这个 g
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    // MARK: - 私有工具

    private static func stripped(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// haystack 是否包含 needle 作为**连续**子序列。
    private static func containsConsecutive(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    private static func tail(of text: String, after index: String.Index) -> String {
        let rest = String(text[index...])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return rest.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : rest
    }
}
