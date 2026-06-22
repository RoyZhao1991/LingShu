import Foundation

/// `apply_patch` 工具接线(差距3·多处编辑,2026-06-21):一次调用多文件/多 hunk、**事务性**(全成或全不改)、
/// 应用后**自动 re-read 校验**。纯事务核在 `LingShuPatchApplier`;这里负责工作目录围栏 + 落盘 + 产出物登记 + diff 卡,
/// 与 `edit_file`/`write_file` 同一套登记口径(appendTaskRecordArtifact / .fileEdit diff / 轨迹)。
@MainActor
extension LingShuState {

    /// 构造 apply_patch 工具(像 applySkillTool 一样单独挂,**不走 parseArgs 扁平化**——hunks 是嵌套数组,
    /// handler 直接拿原始 argsJSON 解析)。recordIDProvider/workingDirectory 由 agentBuiltinTools 注入。
    func applyPatchAgentTool(recordIDProvider: @escaping @MainActor @Sendable () -> String?, workingDirectory: String) -> LingShuAgentTool {
        let schema = """
        {"type":"object","properties":{"hunks":{"type":"array","description":"多文件多处编辑的 hunk 列表;每项 {file:绝对路径, old:要替换的原文(带足上下文以唯一定位;新建文件留空), new:替换为}。事务性:任一 hunk 定位失败则整批不改。","items":{"type":"object","properties":{"file":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["file","new"]}}},"required":["hunks"]}
        """
        return LingShuAgentTool(
            name: "apply_patch",
            description: "一次性对**多个文件、多处**做精确编辑(事务性:全部定位成功才落盘,任一失败整批回滚不改),省去多次 edit_file 往返。每处给 file+old(带足上下文唯一定位;新建文件 old 留空)+new。应用后自动校验。",
            parametersJSON: schema
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            return await self.runApplyPatch(argsJSON: argsJSON, recordID: recordIDProvider(), workingDirectory: workingDirectory)
        }
    }

    /// 执行 apply_patch:解析 → 事务计算(不落盘)→ 工作目录围栏 → 全部落盘 → 自动 re-read 校验 → 登记产出物/diff。
    func runApplyPatch(argsJSON: String, recordID: String?, workingDirectory: String) async -> String {
        guard let hunks = LingShuPatchApplier.parse(argsJSON), !hunks.isEmpty else {
            return "apply_patch 参数无效:需要 {\"hunks\":[{\"file\":\"绝对路径\",\"old\":\"原文\",\"new\":\"新文\"}]}。"
        }
        let normalizedRoot = (workingDirectory as NSString).standardizingPath
        // 工作目录围栏(与 edit_file/write_file 一致):任一 hunk 越界即整批拒绝(事务性,先于落盘)。
        for hunk in hunks {
            let p = (hunk.file as NSString).standardizingPath
            guard p.hasPrefix(normalizedRoot + "/") || p == normalizedRoot else {
                return "apply_patch 拒绝:文件 \(hunk.file) 不在工作目录 \(normalizedRoot) 内(全部未改)。"
            }
        }
        // 事务计算:任一 hunk 失败 → 整批不落盘。
        let plan = LingShuPatchApplier.computePlan(hunks: hunks) { path in
            guard let data = FileManager.default.contents(atPath: (path as NSString).standardizingPath),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }
        let changes: [LingShuPatchApplier.FileChange]
        switch plan {
        case .failure(let f):
            appendTrace(kind: .warning, actor: "工具", title: "apply_patch 回滚", detail: "\(f)(全部未改,事务性)")
            return "apply_patch 失败(事务性,所有文件均未改动):\(f)。请先 read_file 看准、给出能唯一定位的 old 再试。"
        case .success(let c):
            changes = c
        }
        // 录一条 toolCall 卡(供任务窗可读)。
        appendTaskRecordMessage(recordID, actor: "工具", role: "Agent循环", kind: .agent,
                                text: "apply_patch:\(changes.count) 文件",
                                detail: .toolCall(tool: "apply_patch", summary: "事务编辑 \(changes.count) 个文件", arguments: String(argsJSON.prefix(2000))))
        // 全部落盘(事务计算已保证可应用)+ 自动 re-read 校验 + 逐文件登记产出物/diff。
        var written: [String] = []
        var failed: [String] = []
        for change in changes {
            let path = (change.path as NSString).standardizingPath
            let oldContent = change.created ? "" : ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            do {
                if change.created {
                    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                try change.newContent.write(toFile: path, atomically: true, encoding: .utf8)
                // 自动 re-read 校验:落盘内容与计划一致才算成功。
                let reread = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                guard reread == change.newContent else { failed.append((path as NSString).lastPathComponent + "(校验不一致)"); continue }
                let diff = LingShuLineDiff.compute(old: oldContent, new: change.newContent)
                let op: LingShuArtifactOperation = change.created ? .created : .modified
                appendTaskRecordMessage(recordID, actor: "工具", role: "文件改动", kind: .agent,
                                        text: "\(op.rawValue) \((path as NSString).lastPathComponent) (+\(diff.added) -\(diff.removed))",
                                        detail: .fileEdit(path: path, operation: op, added: diff.added, removed: diff.removed, diff: diff.unified))
                appendTaskRecordArtifact(recordID, title: (path as NSString).lastPathComponent, location: path, producer: "apply_patch", operation: op)
                written.append((path as NSString).lastPathComponent)
            } catch {
                failed.append((path as NSString).lastPathComponent + "(\(error.localizedDescription))")
            }
        }
        appendTrace(kind: .tool, actor: "工具", title: "apply_patch 完成", detail: "改了 \(written.count) 个文件\(failed.isEmpty ? "" : ",失败 \(failed.count)")")
        if !failed.isEmpty {
            return "apply_patch 部分落盘异常:成功 \(written.joined(separator: "、"));失败 \(failed.joined(separator: "、"))。"
        }
        return "apply_patch 成功:事务性改了 \(written.count) 个文件(\(written.joined(separator: "、"))),已自动校验落盘一致。"
    }
}
