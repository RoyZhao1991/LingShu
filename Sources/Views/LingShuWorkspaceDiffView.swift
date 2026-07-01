import SwiftUI

/// 「审查」模式:本任务代码改动的真实 diff(对齐 Codex 的 review)。
/// - **git 跟踪的工程**:点开就地跑 `git -C <repoWorkingDir> diff` 拉**真 hunk**,红减绿增。
/// - **非 git 的新工程**(如刚 run_command 现写出来的项目):没有 git diff,改为把**本任务产出的代码文件**
///   当「新增文件」列出,点开读真实文件内容、整页绿底展示——根治"明明写了一堆代码、审查却说没改动"。
struct LingShuWorkspaceDiffView: View {
    let record: LingShuTaskExecutionRecord
    @State private var openPaths: Set<String> = []
    @State private var diffs: [String: [LingShuDiffLine]] = [:]
    @State private var loading: Set<String> = []

    private var summary: LingShuCodeChangeSummary? { record.codeChanges }

    /// git diff 已覆盖的文件绝对路径(用来从产出物里剔掉、避免同一文件两处列)。
    private func gitTrackedAbsPaths() -> Set<String> {
        guard let s = summary, let dir = s.repoWorkingDir else { return [] }
        return Set(s.files.map { ((dir as NSString).appendingPathComponent($0.path) as NSString).standardizingPath })
    }

    /// 本任务产出、但 **git 没跟踪** 的代码/配置文件(新工程的真实交付)。
    private var untrackedCodeArtifacts: [LingShuTaskExecutionArtifact] {
        let tracked = gitTrackedAbsPaths()
        return record.artifacts.filter {
            LingShuState.isCodeLikePath($0.location)
                && !tracked.contains(($0.location as NSString).standardizingPath)
        }
    }

    var body: some View {
        let gitFiles = summary?.files ?? []
        let extras = untrackedCodeArtifacts
        return Group {
            if gitFiles.isEmpty && extras.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if let summary, !gitFiles.isEmpty {
                            header(summary)
                            ForEach(gitFiles) { fileBlock(summary, $0) }
                        }
                        if !extras.isEmpty {
                            artifactSectionHeader(count: extras.count, alongsideGit: !gitFiles.isEmpty)
                            ForEach(extras) { artifactBlock($0) }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func artifactSectionHeader(count: Int, alongsideGit: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.plus").foregroundStyle(.green)
            Text(alongsideGit ? "新增文件（非 git 跟踪）" : "本任务产出的代码文件")
                .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
            Spacer()
            Text("\(count) 个").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.45))
        }
        .padding(.top, alongsideGit ? 6 : 0).padding(.bottom, 2)
    }

    private func artifactBlock(_ a: LingShuTaskExecutionArtifact) -> some View {
        let path = a.location
        let open = openPaths.contains(path)
        let isNew = (a.operation ?? .created) == .created
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggleArtifact(a) } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.5))
                    Text(isNew ? "新增" : "修改").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(isNew ? .green : Color.lingHolo)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background((isNew ? Color.green : Color.lingHolo).opacity(0.15), in: Capsule())
                    Text(a.title).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.82)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if loading.contains(path) { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            if open, let lines = diffs[path] { diffBody(lines) }
        }
    }

    private func toggleArtifact(_ a: LingShuTaskExecutionArtifact) {
        let path = a.location
        if openPaths.contains(path) { openPaths.remove(path); return }
        openPaths.insert(path)
        guard diffs[path] == nil, !loading.contains(path) else { return }
        loading.insert(path)
        Task {
            let content = await Task.detached { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }.value
            let lines: [LingShuDiffLine] = content.isEmpty
                ? [LingShuDiffLine(kind: .ctx, text: "（文件为空或读不到）")]
                : content.components(separatedBy: "\n").prefix(1000).map { LingShuDiffLine(kind: .add, text: $0) }
            await MainActor.run { diffs[path] = lines; loading.remove(path) }
        }
    }

    private func header(_ s: LingShuCodeChangeSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plusminus.circle.fill").foregroundStyle(Color.lingHolo)
            Text(s.repoName).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.9))
            Text(s.branch).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.lingHoloAlt.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Color.lingHoloAlt.opacity(0.12), in: Capsule())
            Spacer()
            Text("\(s.files.count) 个文件改动").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.45))
        }
        .padding(.bottom, 2)
    }

    private func fileBlock(_ s: LingShuCodeChangeSummary, _ f: LingShuCodeChangeSummary.Change) -> some View {
        let open = openPaths.contains(f.path)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(s, f)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.5))
                    Text(f.label).font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(statusColor(f.status))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(statusColor(f.status).opacity(0.15), in: Capsule())
                    Text(f.path).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.82)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if loading.contains(f.path) { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            if open {
                if let lines = diffs[f.path] {
                    diffBody(lines)
                } else if !loading.contains(f.path) {
                    Text("（无 diff 内容）").font(.system(size: 10.5)).foregroundStyle(Color.lingFg.opacity(0.4)).padding(8)
                }
            }
        }
    }

    private func diffBody(_ lines: [LingShuDiffLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(spacing: 0) {
                    Text(line.kind.gutter).font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(line.kind.fg).frame(width: 16, alignment: .center)
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(line.kind == .hunk ? Color.lingHoloAlt.opacity(0.85) : line.kind.fg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6).padding(.vertical, 0.5)
                .background(line.kind.bg)
            }
        }
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 4).padding(.leading, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "plusminus.circle").font(.system(size: 30)).foregroundStyle(Color.lingFg.opacity(0.25))
            Text("本任务没有代码改动").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.lingFg.opacity(0.5))
            Text("有代码交付时,这里按文件列出真实 diff（红减绿增）。").font(.system(size: 10.5)).foregroundStyle(Color.lingFg.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.trimmingCharacters(in: .whitespaces).uppercased() {
        case "A", "AM", "??": return .green
        case "D": return .red
        default: return Color.lingHolo
        }
    }

    private func toggle(_ s: LingShuCodeChangeSummary, _ f: LingShuCodeChangeSummary.Change) {
        if openPaths.contains(f.path) { openPaths.remove(f.path); return }
        openPaths.insert(f.path)
        guard diffs[f.path] == nil, !loading.contains(f.path) else { return }
        guard let dir = s.repoWorkingDir else {
            diffs[f.path] = [LingShuDiffLine(kind: .ctx, text: "（无仓库路径，无法加载 diff）")]; return
        }
        loading.insert(f.path)
        let path = f.path
        let untracked = f.status.contains("?")
        Task {
            let git = await LingShuState.resolveGit(workingDir: dir) ?? "/usr/bin/git"
            let out: String
            if untracked {
                let abs = (dir as NSString).appendingPathComponent(path)
                out = await LingShuState.runCapturing(git, ["-C", dir, "diff", "--no-index", "--no-color", "/dev/null", abs])
            } else {
                out = await LingShuState.runCapturing(git, ["-C", dir, "diff", "--no-color", "HEAD", "--", path])
            }
            let parsed = LingShuWorkspaceDiffView.parseDiff(out)
            await MainActor.run {
                diffs[path] = parsed.isEmpty ? [LingShuDiffLine(kind: .ctx, text: "（无差异或已提交）")] : parsed
                loading.remove(path)
            }
        }
    }

    /// 解析 unified diff 文本为可渲染行(纯函数,可测)。
    static func parseDiff(_ raw: String) -> [LingShuDiffLine] {
        var out: [LingShuDiffLine] = []
        for line in raw.components(separatedBy: "\n") {
            if line.isEmpty { continue }   // 空行=尾随换行/非 hunk 空白的切分残渣;hunk 内空行是 " "(空格前缀)不受影响
            if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity")
                || line.hasPrefix("rename ") || line.hasPrefix("old mode") || line.hasPrefix("new mode") { continue }
            if line.hasPrefix("@@") { out.append(LingShuDiffLine(kind: .hunk, text: line)); continue }
            if line.hasPrefix("+") { out.append(LingShuDiffLine(kind: .add, text: String(line.dropFirst()))) }
            else if line.hasPrefix("-") { out.append(LingShuDiffLine(kind: .del, text: String(line.dropFirst()))) }
            else { out.append(LingShuDiffLine(kind: .ctx, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line)) }
        }
        return out
    }
}

/// diff 一行的语义类别(增/减/上下文/hunk头)。
struct LingShuDiffLine: Identifiable {
    let id = UUID()
    let kind: Kind
    let text: String
    enum Kind {
        case add, del, ctx, hunk
        var gutter: String { switch self { case .add: return "+"; case .del: return "-"; case .hunk: return "@"; case .ctx: return "" } }
        var fg: Color {
            switch self {
            case .add: return Color(red: 0.55, green: 0.92, blue: 0.6)
            case .del: return Color(red: 0.98, green: 0.55, blue: 0.55)
            case .hunk: return Color.lingHoloAlt
            case .ctx: return Color.lingFg.opacity(0.62)
            }
        }
        var bg: Color {
            switch self {
            case .add: return Color.green.opacity(0.1)
            case .del: return Color.red.opacity(0.1)
            default: return .clear
            }
        }
    }
}
