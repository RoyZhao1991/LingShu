import SwiftUI
import AppKit

/// 完全版 #8·**编辑-审查闭环 UI**(Codex/Claude 看家体验):工作区 git diff → 文件树 + 逐 hunk 接受/拒绝 + 回退未接受。
/// 灵枢的编辑已落盘,故"拒绝某块"= `git apply --reverse` 回退该块(把未接受的 hunk 组装成补丁反向应用)。
/// 视图层薄薄一层,核在纯逻辑 `LingShuWorkspaceReview`(已单测)。

@MainActor
final class LingShuWorkspaceReviewModel: ObservableObject {
    @Published var files: [LingShuReviewFile] = []
    @Published var loading = false
    @Published var message = ""
    let workingDir: String

    init(workingDir: String) { self.workingDir = workingDir }

    func load() async {
        loading = true; message = ""
        let dir = workingDir
        let diff = await Task.detached { LingShuWorkspaceReviewGit.diff(dir: dir) }.value
        files = LingShuWorkspaceReview.parse(unifiedDiff: diff)
        loading = false
        if files.isEmpty { message = "工作区没有未提交的代码改动。" }
    }

    func setAccepted(_ accepted: Bool, fileIndex: Int, hunkIndex: Int) {
        guard files.indices.contains(fileIndex), files[fileIndex].hunks.indices.contains(hunkIndex) else { return }
        files[fileIndex].hunks[hunkIndex].accepted = accepted
    }

    /// 回退所有"未接受"的 hunk(组装成补丁 → git apply --reverse)。
    func revertRejected() async {
        // 反选:把"被拒绝(accepted=false)"的当作要组装的块。
        let toRevert = files.map { f -> LingShuReviewFile in
            var f2 = f
            f2.hunks = f.hunks.map { var h = $0; h.accepted = !$0.accepted; return h }
            return f2
        }
        let patch = LingShuWorkspaceReview.assembleAcceptedPatch(toRevert)
        guard !patch.isEmpty else { message = "没有未接受的改动需要回退。"; return }
        let dir = workingDir
        let ok = await Task.detached { LingShuWorkspaceReviewGit.applyReverse(patch: patch, dir: dir) }.value
        message = ok ? "已回退未接受的改动。" : "回退失败:补丁与当前工作树不匹配(可能文件又被改过)。"
        await load()
    }

    var summary: (files: Int, acceptedHunks: Int, added: Int, removed: Int) { LingShuWorkspaceReview.summary(files) }
}

struct LingShuWorkspaceReviewView: View {
    let workingDir: String
    @StateObject private var model: LingShuWorkspaceReviewModel
    @State private var openFiles: Set<String> = []
    @State private var confirmRevert = false

    init(workingDir: String) {
        self.workingDir = workingDir
        _model = StateObject(wrappedValue: LingShuWorkspaceReviewModel(workingDir: workingDir))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBar
            Divider()
            if model.loading {
                ProgressView("读取改动…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.files.isEmpty {
                Text(model.message.isEmpty ? "无改动" : model.message)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 8) { fileList } .padding(8) }
            }
        }
        .task { await model.load() }
    }

    private var summaryBar: some View {
        let s = model.summary
        return HStack(spacing: 12) {
            Image(systemName: "plusminus.circle")
            Text("\(s.files) 文件 · 接受 \(s.acceptedHunks) 块").font(.system(size: 12, weight: .medium))
            Text("+\(s.added)").foregroundStyle(.green).font(.system(size: 12))
            Text("−\(s.removed)").foregroundStyle(.red).font(.system(size: 12))
            Spacer()
            Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("重新读取")
            Button(role: .destructive) { confirmRevert = true } label: {
                Label("回退未接受", systemImage: "arrow.uturn.backward")
            }
            .controlSize(.small)
            .disabled(model.files.allSatisfy { $0.hunks.allSatisfy(\.accepted) })
            .confirmationDialog("回退所有未接受(已取消勾选)的改动?此操作会修改工作区文件。", isPresented: $confirmRevert) {
                Button("回退未接受的改动", role: .destructive) { Task { await model.revertRejected() } }
                Button("取消", role: .cancel) {}
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var fileList: some View {
        ForEach(Array(model.files.enumerated()), id: \.element.path) { fi, file in
            let isOpen = openFiles.contains(file.path)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if isOpen { openFiles.remove(file.path) } else { openFiles.insert(file.path) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(file.path).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(file.acceptedHunkCount)/\(file.hunks.count) 块").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain)
                if isOpen {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { hi, hunk in
                        hunkView(fi: fi, hi: hi, hunk: hunk)
                    }
                }
            }
            .padding(8)
            .background(Color.lingFg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func hunkView(fi: Int, hi: Int, hunk: LingShuReviewHunk) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hunk.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("接受", isOn: Binding(
                    get: { hunk.accepted },
                    set: { model.setAccepted($0, fileIndex: fi, hunkIndex: hi) }
                )).toggleStyle(.switch).controlSize(.mini)
            }
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                Text(line.raw.isEmpty ? " " : line.raw)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(color(line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bg(line.kind))
                    .opacity(hunk.accepted ? 1 : 0.4)
            }
        }
        .padding(6)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(_ k: LingShuReviewLine.Kind) -> Color {
        switch k { case .add: return .green; case .remove: return .red; case .context: return .primary.opacity(0.75) }
    }
    private func bg(_ k: LingShuReviewLine.Kind) -> Color {
        switch k { case .add: return .green.opacity(0.10); case .remove: return .red.opacity(0.10); case .context: return .clear }
    }
}
