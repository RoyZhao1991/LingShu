import SwiftUI

/// 「文件」模式:工作区文件树 + 点开 inline 预览(对齐 Codex 的"打开文件")。
/// 左=预览区(选中文件就地渲染,复用 `LingShuInlineArtifactPreview` 的网页/图片/音视频/QuickLook 多类型),右=可筛选的目录树。
/// 根目录优先取本任务仓库工作树,其次产出物所在目录,最后用户主目录。
struct LingShuWorkspaceFileTree: View {
    let record: LingShuTaskExecutionRecord
    @State private var selected: URL?
    @State private var filter: String = ""

    private var root: URL {
        if let dir = record.codeChanges?.repoWorkingDir, !dir.isEmpty { return URL(fileURLWithPath: dir) }
        if let loc = record.artifacts.first?.location.trimmingCharacters(in: .whitespaces), !loc.isEmpty {
            return URL(fileURLWithPath: loc).deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左:预览区
            Group {
                if let selected {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.lingHolo)
                            Text(selected.lastPathComponent).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.lingFg.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([selected]) } label: {
                                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Color.lingFg.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .help(LingShuLanguagePreferenceStore.localized("在 Finder 中显示", "Show in Finder"))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.black.opacity(0.4))
                        LingShuInlineArtifactPreview(fileURL: selected)
                    }
                } else {
                    emptyPreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.lingFg.opacity(0.08))

            // 右:文件树 + 筛选
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Color.lingFg.opacity(0.4))
                    TextField(LingShuLanguagePreferenceStore.localized("筛选文件…", "Filter files…"), text: $filter)
                        .textFieldStyle(.plain).font(.system(size: 11.5))
                        .foregroundStyle(Color.lingFg.opacity(0.9))
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Color.lingFg.opacity(0.05))
                Divider().overlay(Color.lingFg.opacity(0.06))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        LingShuFileTreeNode(url: root, depth: 0, filter: filter, selected: $selected)
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(width: 300)
            .background(Color.black.opacity(0.22))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 32)).foregroundStyle(Color.lingFg.opacity(0.25))
            Text(LingShuLanguagePreferenceStore.localized("打开文件", "Open a File"))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.55))
            Text(LingShuLanguagePreferenceStore.localized("从右侧工作区目录树中选择文件", "Select a file from the workspace tree"))
                .font(.system(size: 11)).foregroundStyle(Color.lingFg.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 文件树节点(递归):目录懒加载子项、点开/收起;文件点选 → 左侧预览。
struct LingShuFileTreeNode: View {
    let url: URL
    let depth: Int
    let filter: String
    @Binding var selected: URL?
    @State private var expanded = false
    @State private var children: [URL]?

    private static let skipDirs: Set<String> = [".git", ".build", "node_modules", "DerivedData", "__pycache__", ".swiftpm", ".venv", "Pods"]

    private var isDir: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    private var filteredOut: Bool {
        // 文件:筛选词非空且名字不含 → 隐藏;目录始终显示(便于导航)。
        !filter.isEmpty && !isDir && !url.lastPathComponent.localizedCaseInsensitiveContains(filter)
    }

    var body: some View {
        if filteredOut {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                row
                if expanded, let children {
                    ForEach(children, id: \.path) { child in
                        LingShuFileTreeNode(url: child, depth: depth + 1, filter: filter, selected: $selected)
                    }
                }
            }
        }
    }

    private var row: some View {
        Button {
            if isDir {
                expanded.toggle()
                if expanded, children == nil { loadChildren() }
            } else {
                selected = url
            }
        } label: {
            HStack(spacing: 5) {
                if isDir {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.45)).frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: isDir ? "folder.fill" : "doc.text")
                    .font(.system(size: 10)).foregroundStyle(isDir ? Color.lingHoloAlt.opacity(0.8) : Color.lingFg.opacity(0.5))
                Text(url.lastPathComponent).font(.system(size: 11, weight: isDir ? .semibold : .regular))
                    .foregroundStyle(selected == url ? Color.lingHolo : Color.lingFg.opacity(0.82)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 11 + 8).padding(.trailing, 8).padding(.vertical, 3)
            .background(selected == url ? Color.lingHolo.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadChildren() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        children = items
            .filter { !Self.skipDirs.contains($0.lastPathComponent) }
            .sorted { a, b in
                let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if ad != bd { return ad }   // 目录在前
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
    }
}
