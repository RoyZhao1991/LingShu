import Foundation

/// `apply_patch` 的**纯逻辑事务核**(差距3·多处编辑,2026-06-21)。
///
/// 一次调用含**多文件、多 hunk**;每 hunk = {file, old, new},复用 `LingShuEditReplacer` 的多策略匹配级联做替换。
/// **事务性**:任一 hunk 定位失败(notFound/multiple/disproportionate)→ **整批不落盘**(返回 failure,调用方一个字节都不写),
/// 杜绝"改了一半"。同一文件的多个 hunk 按序在内存累积应用(后一个在前一个结果上找)。空 old + 新文件 = 创建。
/// 文件读取注入(`read`),纯函数、可单测、无副作用。通用零定制。
enum LingShuPatchApplier {

    struct Hunk: Equatable {
        let file: String
        let oldString: String
        let newString: String
    }

    struct FileChange: Equatable {
        let path: String
        let newContent: String
        let created: Bool          // 本批新建(原先不存在)
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyPatch
        case hunkFailed(file: String, index: Int, reason: String)
        var description: String {
            switch self {
            case .emptyPatch: return "补丁为空(没有任何 hunk)"
            case .hunkFailed(let f, let i, let r): return "第 \(i + 1) 个 hunk(\(f))定位失败:\(r)"
            }
        }
    }

    // MARK: 解析 JSON 信封 → hunks(容错别名:file/path、old/old_string、new/new_string)

    static func parse(_ json: String) -> [Hunk]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawHunks = obj["hunks"] as? [[String: Any]] else { return nil }
        var hunks: [Hunk] = []
        for h in rawHunks {
            let file = (h["file"] as? String) ?? (h["path"] as? String) ?? ""
            let old = (h["old"] as? String) ?? (h["old_string"] as? String) ?? ""
            let new = (h["new"] as? String) ?? (h["new_string"] as? String) ?? ""
            guard !file.isEmpty else { continue }
            hunks.append(Hunk(file: file, oldString: old, newString: new))
        }
        return hunks
    }

    // MARK: 事务性计算(不落盘)——所有 hunk 成功才返回全部文件新内容

    /// `read(path)` 返回当前内容;nil = 文件不存在(空 old 时按新建处理)。
    static func computePlan(hunks: [Hunk], read: (String) -> String?) -> Result<[FileChange], Failure> {
        guard !hunks.isEmpty else { return .failure(.emptyPatch) }
        var contents: [String: String] = [:]
        var created: Set<String> = []
        var order: [String] = []

        for (i, hunk) in hunks.enumerated() {
            let path = hunk.file
            if contents[path] == nil {
                if let existing = read(path) {
                    contents[path] = existing
                } else {
                    contents[path] = ""
                    created.insert(path)
                }
                order.append(path)
            }
            let current = contents[path] ?? ""

            if hunk.oldString.isEmpty {
                // 空 old:仅当文件为空/新建时合法(= 写入/创建);文件已有内容则无法定位,失败。
                if current.isEmpty {
                    contents[path] = hunk.newString
                    continue
                }
                return .failure(.hunkFailed(file: path, index: i, reason: "old 为空但文件非空,无法定位(改已有文件请给出 old 上下文)"))
            }

            switch LingShuEditReplacer.replace(content: current, oldString: hunk.oldString, newString: hunk.newString) {
            case .replaced(let updated):
                contents[path] = updated
            case .identical:
                break   // old == new:空操作,内容不变
            case .emptyOld:
                return .failure(.hunkFailed(file: path, index: i, reason: "old 为空"))
            case .notFound:
                return .failure(.hunkFailed(file: path, index: i, reason: "没找到 old(已试多策略匹配),先读准再改"))
            case .multiple:
                return .failure(.hunkFailed(file: path, index: i, reason: "old 匹配到多处,请带更多上下文"))
            case .disproportionate:
                return .failure(.hunkFailed(file: path, index: i, reason: "匹配片段比 old 大太多,拒绝以防误改"))
            }
        }
        let changes = order.map { FileChange(path: $0, newContent: contents[$0] ?? "", created: created.contains($0)) }
        return .success(changes)
    }
}
