import SwiftUI

/// # 多模态工作区面板(对齐 Codex 右侧"一个面板按需开标签")
///
/// 不一次性铺满所有模式——**起步只开当前需要的(概览),其余通过 `+` 按需追加**(对齐 Codex)。每个标签可关。
/// - **概览**:复用 `TaskDevToolsPanel`(目标/产出物/Git),作为常驻锚标签不可关。
/// - **审查**:本任务真 `git diff`(红减绿增)。
/// - **文件**:工作区文件树 + 点开 inline 预览。
/// - **浏览器**:复用进程内 `LingShuBrowserChrome`。
/// - **终端**:真·系统命令行 `LingShuWorkspaceTerminalView`(zsh)。
///
/// 右上「展开」:折叠=460 侧栏(左时间线在);展开=铺满(隐时间线),给浏览器/终端/文件树宽度。
struct LingShuWorkspacePanel: View {
    @ObservedObject var state: LingShuState
    let record: LingShuTaskExecutionRecord
    let lineageRecords: [LingShuTaskExecutionRecord]
    @Binding var expanded: Bool
    @State private var openTabs: [Mode] = [.overview]
    @State private var mode: Mode = .overview

    enum Mode: String, CaseIterable, Identifiable {
        case overview = "概览"
        case review = "审查"
        case files = "文件"
        case browser = "浏览器"
        case terminal = "终端"
        var id: String { rawValue }
        var englishName: String {
            switch self {
            case .overview: "Overview"
            case .review: "Review"
            case .files: "Files"
            case .browser: "Browser"
            case .terminal: "Terminal"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "rectangle.3.group"
            case .review: return "plusminus.circle"
            case .files: return "folder"
            case .browser: return "globe"
            case .terminal: return "terminal"
            }
        }
    }

    /// 宽模式(浏览器/文件树/终端)需要横向空间,选中即自动展开铺满。
    private static let wideModes: Set<Mode> = [.browser, .files, .terminal]

    /// 「审查」标签计数:git 跟踪的改动文件 + 本任务产出的代码/配置文件(非 git 的新工程也能反映)。
    private var reviewCount: Int {
        if let n = record.codeChanges?.files.count, n > 0 { return n }
        return record.artifacts.filter { LingShuState.isCodeLikePath($0.location) }.count
    }

    /// 工作区根:优先本任务仓库,其次产出物所在目录,最后用户主目录(供终端/文件树)。
    private var workspaceRoot: URL {
        if let dir = record.codeChanges?.repoWorkingDir, !dir.isEmpty { return URL(fileURLWithPath: dir) }
        if let loc = record.artifacts.first?.location.trimmingCharacters(in: .whitespaces), !loc.isEmpty {
            return URL(fileURLWithPath: loc).deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.lingFg.opacity(0.08))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.lingVoid)
    }

    // MARK: - 标签栏(已开标签 + `+` 追加 + 展开钮)

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(openTabs) { tabChip($0) }
            addMenu
            Spacer(minLength: 4)
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.7))
                    .frame(width: 26, height: 24)
                    .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(expanded
                  ? state.loc("收起为侧栏", "Collapse to Sidebar")
                  : state.loc("展开铺满窗口", "Expand to Full Window"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.lingBar)   // 浅=白 chrome / 深=半透明暗条(原 black@0.5 在浅色=突兀暗块)
        .overlay(alignment: .bottom) { Divider().overlay(Color.lingFg.opacity(0.08)) }
    }

    private func tabChip(_ m: Mode) -> some View {
        let active = mode == m
        return HStack(spacing: 6) {
            Button { select(m) } label: {
                HStack(spacing: 5) {
                    Image(systemName: m.icon).font(.system(size: 10.5, weight: .bold))
                    Text(state.loc(m.rawValue, m.englishName)).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    if m == .review, reviewCount > 0 {
                        Text("\(reviewCount)").font(.system(size: 9, weight: .bold, design: .monospaced)).opacity(0.7)
                    }
                }
                .foregroundStyle(active ? Color.lingVoid : Color.lingFg.opacity(0.82))
            }
            .buttonStyle(.plain)
            // 概览是常驻锚标签,不可关;其余可关。
            if m != .overview {
                Button { close(m) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(active ? Color.lingVoid.opacity(0.7) : Color.lingFg.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(active ? Color.lingHolo : Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var addMenu: some View {
        let closed = Mode.allCases.filter { !openTabs.contains($0) }
        return Menu {
            if closed.isEmpty {
                Text(state.loc("已全部打开", "All Open"))
            } else {
                ForEach(closed) { m in
                    Button { open(m) } label: { Label(state.loc(m.rawValue, m.englishName), systemImage: m.icon) }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.75))
                .frame(width: 26, height: 24)
                .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.loc("追加一个模式标签", "Add a Workspace Tab"))
    }

    private func select(_ m: Mode) {
        mode = m
        if Self.wideModes.contains(m) && !expanded { withAnimation(.easeInOut(duration: 0.16)) { expanded = true } }
    }

    private func open(_ m: Mode) {
        if !openTabs.contains(m) { openTabs.append(m) }
        select(m)
    }

    private func close(_ m: Mode) {
        openTabs.removeAll { $0 == m }
        if openTabs.isEmpty { openTabs = [.overview] }
        if mode == m { mode = openTabs.last ?? .overview }
    }

    // MARK: - 各模式内容(复用既有能力 + 新视图)

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .overview:
            TaskDevToolsPanel(state: state, record: record, lineageRecords: lineageRecords)
        case .review:
            // #8 编辑-审查闭环:工作区改动按文件+逐 hunk 接受/拒绝、回退未接受(Codex/Claude 式)。
            // 非 git 工程/产出物概览仍可在「概览」「文件」tab 看。
            LingShuWorkspaceReviewView(workingDir: workspaceRoot.path)
        case .files:
            LingShuWorkspaceFileTree(record: record)
        case .browser:
            LingShuBrowserChrome(controller: state.browserController)
        case .terminal:
            LingShuWorkspaceTerminalView(initialDir: workspaceRoot)
        }
    }
}
