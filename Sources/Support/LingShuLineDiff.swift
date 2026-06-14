import Foundation

/// 行级 diff(LCS)——独立纯算法模块:给文件改动卡片算增删行数 + 生成统一 diff 文本
/// (对齐 codex 编辑卡的 +N/-N),并支持从 diff 无损还原改前内容(撤销用)。
/// 不依赖 UI/State,可单测;供任务窗口 diff 卡 + 撤销复用。
enum LingShuLineDiff {
    struct Result: Equatable, Sendable {
        var added: Int
        var removed: Int
        var unified: String
    }

    /// 计算 old→new 的行级 diff。`maxLines` 防超大文件把 diff 撑爆持久化(超出截断并标注)。
    static func compute(old: String, new: String, maxLines: Int = 240) -> Result {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        // LCS 表(行级)。
        let m = oldLines.count, n = newLines.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    lcs[i][j] = oldLines[i] == newLines[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var lines: [String] = []
        var added = 0, removed = 0
        var i = 0, j = 0
        while i < m && j < n {
            if oldLines[i] == newLines[j] {
                lines.append("  " + oldLines[i]); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                lines.append("- " + oldLines[i]); removed += 1; i += 1
            } else {
                lines.append("+ " + newLines[j]); added += 1; j += 1
            }
        }
        while i < m { lines.append("- " + oldLines[i]); removed += 1; i += 1 }
        while j < n { lines.append("+ " + newLines[j]); added += 1; j += 1 }

        var unified = lines
        if unified.count > maxLines {
            unified = Array(unified.prefix(maxLines)) + [truncationMarker(totalChanges: lines.count)]
        }
        return Result(added: added, removed: removed, unified: unified.joined(separator: "\n"))
    }

    static func truncationMarker(totalChanges: Int) -> String { "… (diff 过长已截断,共 \(totalChanges) 行变更)" }

    /// diff 是否被截断(截断的不可无损还原 → 撤销禁用)。
    static func isTruncated(_ unified: String) -> Bool { unified.contains("diff 过长已截断") }

    /// 从统一 diff 还原**改前内容**(撤销用):取上下文行(`  `)与删除行(`- `),丢弃新增行(`+ `)。
    /// diff 被截断时返回 nil(无法无损还原)。
    static func reconstructOld(fromUnified unified: String) -> String? {
        guard !isTruncated(unified) else { return nil }
        let old = unified.components(separatedBy: "\n").compactMap { line -> String? in
            if line.hasPrefix("  ") || line.hasPrefix("- ") { return String(line.dropFirst(2)) }
            return nil   // "+ " 新增行不在改前内容里
        }
        return old.joined(separator: "\n")
    }
}
