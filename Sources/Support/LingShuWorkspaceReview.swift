import Foundation

/// 完全版 #8·**编辑-审查闭环(模型核)**(纯逻辑、可测)——补 Codex/Claude 看家本事:文件树 + 补丁预览 + 逐块接受。
///
/// 把一份 unified diff(git diff)解析成 文件→hunk 结构,支持**逐块接受/拒绝**,再把**已接受的块**重新组装成
/// 可 `git apply` 的补丁。UI(文件树/逐块勾选)在此模型之上薄薄一层;这里是可单测的backbone。
struct LingShuReviewLine: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case context, add, remove }
    let kind: Kind
    let text: String          // 不含前导 +/-/空格 标记
    var raw: String {          // 还原成补丁行(带标记)
        switch kind { case .context: return " " + text; case .add: return "+" + text; case .remove: return "-" + text }
    }
}

struct LingShuReviewHunk: Sendable, Equatable {
    let header: String         // @@ -a,b +c,d @@ ...
    let lines: [LingShuReviewLine]
    var accepted: Bool = true  // 默认接受;UI 可逐块切
    var added: Int { lines.filter { $0.kind == .add }.count }
    var removed: Int { lines.filter { $0.kind == .remove }.count }
}

struct LingShuReviewFile: Sendable, Equatable {
    let path: String           // b/ 侧路径(新文件名)
    let headerLines: [String]  // diff --git / index / --- / +++ 这些文件头行
    var hunks: [LingShuReviewHunk]
    var acceptedHunkCount: Int { hunks.filter(\.accepted).count }
}

enum LingShuWorkspaceReview {
    /// 解析 unified diff → 文件 + hunk。容错:非 diff 文本返回空。
    static func parse(unifiedDiff: String) -> [LingShuReviewFile] {
        var files: [LingShuReviewFile] = []
        var curHeader: [String] = []
        var curPath = ""
        var curHunks: [LingShuReviewHunk] = []
        var hunkHeader: String?
        var hunkLines: [LingShuReviewLine] = []

        func flushHunk() {
            if let h = hunkHeader { curHunks.append(.init(header: h, lines: hunkLines)); hunkHeader = nil; hunkLines = [] }
        }
        func flushFile() {
            flushHunk()
            if !curPath.isEmpty || !curHunks.isEmpty {
                files.append(.init(path: curPath, headerLines: curHeader, hunks: curHunks))
            }
            curHeader = []; curPath = ""; curHunks = []
        }

        for line in unifiedDiff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git") {
                flushFile(); curHeader = [line]
            } else if line.hasPrefix("@@") {
                flushHunk(); hunkHeader = line
            } else if hunkHeader != nil {
                if line.hasPrefix("+") { hunkLines.append(.init(kind: .add, text: String(line.dropFirst()))) }
                else if line.hasPrefix("-") { hunkLines.append(.init(kind: .remove, text: String(line.dropFirst()))) }
                else if line.hasPrefix(" ") { hunkLines.append(.init(kind: .context, text: String(line.dropFirst()))) }
                // 真实空行在 unified diff 里是 " "(空格),已被上面捕获;完全空串("")只是按 \n split 的尾部产物,忽略。
                // 其它(\ No newline 等)忽略
            } else {
                if line.hasPrefix("+++ ") {
                    var p = String(line.dropFirst(4))
                    if p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
                    curPath = p
                }
                curHeader.append(line)
            }
        }
        flushFile()
        return files
    }

    /// 把**已接受的 hunk** 重组成可 git apply 的补丁(整文件 hunk 全没接受则跳过该文件)。
    static func assembleAcceptedPatch(_ files: [LingShuReviewFile]) -> String {
        var out: [String] = []
        for f in files {
            let accepted = f.hunks.filter(\.accepted)
            guard !accepted.isEmpty else { continue }
            out.append(contentsOf: f.headerLines)
            for h in accepted {
                out.append(h.header)
                out.append(contentsOf: h.lines.map(\.raw))
            }
        }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"   // 尾随换行:git apply 要求补丁以换行结束
    }

    /// 汇总(给文件树/状态栏):文件数、接受块数、+/- 行数。
    static func summary(_ files: [LingShuReviewFile]) -> (files: Int, acceptedHunks: Int, added: Int, removed: Int) {
        let accepted = files.flatMap { $0.hunks.filter(\.accepted) }
        return (files.count, accepted.count, accepted.reduce(0) { $0 + $1.added }, accepted.reduce(0) { $0 + $1.removed })
    }
}
