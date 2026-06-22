import Foundation

/// 本机知识索引·**文本分块器**(纯逻辑,可单测)。
///
/// 把长文档切成带重叠的块,供逐块 embedding + 检索(命中块比命中整文件更精准)。
/// 尽量在换行/句号边界断开,块间留少量重叠避免把一句话切两半导致语义丢失。通用、无副作用。
enum LingShuTextChunker {
    /// 切块:`maxChars` 单块上限、`overlap` 相邻块重叠字符数。短文本原样一块。
    static func chunk(_ text: String, maxChars: Int = 1200, overlap: Int = 150) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let chars = Array(trimmed)
        guard chars.count > maxChars else { return [trimmed] }

        let cap = max(200, maxChars)
        let ov = max(0, min(overlap, cap / 2))
        var chunks: [String] = []
        var start = 0
        while start < chars.count {
            let hardEnd = min(start + cap, chars.count)
            var cut = hardEnd
            if hardEnd < chars.count {
                // 在后半窗口里往回找最近的自然断点(换行/句号),让块在语义边界结束。
                let windowStart = max(start + cap / 2, hardEnd - 200)
                if let brk = (windowStart..<hardEnd).reversed().first(where: {
                    let c = chars[$0]; return c == "\n" || c == "。" || c == "." || c == "!" || c == "?" || c == "！" || c == "？"
                }) {
                    cut = brk + 1
                }
            }
            let piece = String(chars[start..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            if cut >= chars.count { break }
            start = max(cut - ov, start + 1)   // 重叠 + 保证前进(防死循环)
        }
        return chunks
    }
}
