import Foundation

/// 语音收口后、调用大模型前的**有意义性判定**(纯函数、零成本、不调模型)。
///
/// 目的:连续聆听会把"嗯/啊/呃"这类语气词、纯标点、ASR 噪声也收成一句;若直接喂大模型既费钱又会
/// 冒出莫名其妙的回应。这里用廉价规则先筛掉**无意义**的输入,直接放弃、转待机,不惊动大脑。
/// 判据保守:**只筛掉明显的语气词/标点/空白**,真内容(哪怕"停""好""对"这种单字命令)一律放行,宁可
/// 偶尔多处理一句,也不误杀真指令。
enum LingShuUtteranceMeaning {
    /// 中文语气词/叹词(单字):整句去掉这些 + 标点 + 空白后若什么都不剩 = 无意义。
    /// 不含"是/好/对/不/行/停/要"等可作命令/应答的实义单字。
    static let fillerChars: Set<Character> = [
        "嗯", "唔", "呃", "啊", "哦", "噢", "喔", "哈", "呵", "嘿", "诶", "欸", "唉",
        "呀", "呐", "呢", "吧", "啦", "嘛", "咯", "喏", "哎", "嗷", "嗨", "额", "呜", "哼"
    ]

    /// 纯英文语气词(整句小写字母后整体匹配 = 无意义)。
    static let latinFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "hmm", "mm", "mmm", "ah", "ahh", "oh", "ohh",
        "er", "erm", "mhm", "huh", "eh"
    ]

    /// 这句话是否值得调用大模型。false = 无意义(空/纯标点/纯语气词/纯噪声),应直接放弃转待机。
    static func isMeaningful(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 纯英文语气词(去标点/空白后只剩字母,整体落在 latinFillers)。
        let letters = trimmed.lowercased().filter { $0.isLetter }
        let nonLetterNonSpace = trimmed.contains { !$0.isLetter && !$0.isWhitespace && !$0.isPunctuation }
        if !letters.isEmpty, !nonLetterNonSpace, latinFillers.contains(letters) {
            return false
        }

        // 去掉空白、标点、符号、中文语气词后,还剩实义字符才算有意义。
        let content = trimmed.filter { ch in
            !ch.isWhitespace && !ch.isPunctuation && !ch.isSymbol && !fillerChars.contains(ch)
        }
        return !content.isEmpty
    }
}
