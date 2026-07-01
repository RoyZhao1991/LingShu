import SwiftUI
import AppKit

struct TaskExecutionRecordSheet: View {
    @ObservedObject var state: LingShuState
    @Environment(\.dismiss) private var dismiss
    /// 选中的参与 agent(nil=全部):点参与方过滤栏里某个 agent → 时间线只看它的对话。差距6 可见性落到子页面。
    @State private var selectedAgent: String?
    /// 多模态工作区面板是否展开铺满(隐藏左侧时间线)。
    @State private var workspaceExpanded = false
    /// 是否隐藏右侧多模态面板(对齐 Codex 右栏可隐藏):隐藏后时间线独占整窗。
    @State private var panelHidden = false

    // 从 state 实时取记录:执行流/diff/追问续跑都会即时反映到窗口。
    private var record: LingShuTaskExecutionRecord? { state.selectedTaskRecord }
    private var lineageRecords: [LingShuTaskExecutionRecord] { state.selectedTaskRecordLineage }

    /// 真正参与本任务的 agent 列表(按出场顺序去重 + 各自消息数)——参与方过滤栏的数据。
    /// 排除**内部机制标签**(Agent循环/中枢/系统是循环/路由的实现细节,不是参与的 agent)和用户本人(你)。
    private static let nonAgentActors: Set<String> = ["你", "Agent循环", "中枢", "系统", "编排"]
    private func agentList(_ record: LingShuTaskExecutionRecord) -> [(name: String, count: Int)] {
        var order: [String] = []; var counts: [String: Int] = [:]
        for m in record.messages {
            let a = m.actor.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, !Self.nonAgentActors.contains(a) else { continue }
            if counts[a] == nil { order.append(a) }
            counts[a, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    var body: some View {
        Group {
            if let record {
                content(record: record)
            } else {
                Color.lingVoid.frame(minWidth: 1020, minHeight: 620)
            }
        }
    }

    private func content(record: LingShuTaskExecutionRecord) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                    .frame(width: 42, height: 42)
                    .background(Color.lingHolo.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.lingFg)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(record.status.rawValue)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(record.status.color)
                        Text("\(agentList(record).count) 个参与方")   // 与下方过滤 chip 同源(排除「你」+内部机制标签),不再头部5/下面4 对不上
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.lingFg.opacity(0.52))
                        Text(record.updatedAt.taskRecordDisplayTime)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.lingFg.opacity(0.42))
                        // 开发任务:头部补仓库 + 分支 chip(对齐 codex 开发窗口)。
                        if let code = record.codeChanges {
                            headerChip(code.repoName, icon: "folder.fill")
                            headerChip(code.branch, icon: "arrow.triangle.branch")
                        }
                    }
                }

                Spacer()

                if state.canStopTaskWindowRecord(record.id) {
                    Button {
                        state.stopTaskWindowRecord(record.id)
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.red.opacity(0.94))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(Color.red.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("停止当前任务")
                }

                // 右栏显隐切换(对齐 Codex 可隐藏右侧面板):隐藏后时间线独占整窗。
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { panelHidden.toggle() }
                } label: {
                    Image(systemName: panelHidden ? "sidebar.right" : "rectangle.righthalf.inset.filled")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(panelHidden ? Color.lingFg.opacity(0.5) : Color.lingHolo)
                        .frame(width: 30, height: 30)
                        .background(Color.lingFg.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(panelHidden ? "显示右侧面板" : "隐藏右侧面板")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.72))
                        .frame(width: 30, height: 30)
                        .background(Color.lingFg.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .background(Color.lingBar)   // 跟随外观:浅=白 chrome / 深=半透明暗条(原 black@0.72 在浅色=突兀黑条)
            .overlay(alignment: .bottom) { Divider().overlay(Color.lingFg.opacity(0.08)) }

            HStack(spacing: 0) {
                // 左时间线:面板展开铺满时隐藏(给浏览器/终端/文件树宽度);面板隐藏时则始终显示、独占整窗。
                if !workspaceExpanded || panelHidden {
                    VStack(spacing: 0) {
                        agentFilterBar(record: record)
                        timelineColumn(record: record)
                        Divider().overlay(Color.lingFg.opacity(0.08))
                        // 窗口内追问 + 模型选择 + 反馈(codex 式聊天窗口)。
                        TaskWindowFooter(state: state, recordID: record.id)
                    }
                    if !panelHidden {
                        Divider().overlay(Color.lingFg.opacity(0.1))
                    }
                }
                // 右侧多模态面板:概览/审查/文件/浏览器/终端 一键切;可经标题栏按钮整列隐藏。
                if !panelHidden {
                    LingShuWorkspacePanel(state: state, record: record, lineageRecords: lineageRecords, expanded: $workspaceExpanded)
                        .frame(width: workspaceExpanded ? nil : 460)
                }
            }
        }
        .frame(minWidth: 1020, minHeight: 620)
        .background(Color.lingVoid)
    }

    private func headerChip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(Color.lingHoloAlt.opacity(0.9))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Color.lingHoloAlt.opacity(0.12), in: Capsule())
    }

    /// 参与方过滤栏:列出真正参与本任务的 agent(命名角色/审查员/工具/中枢…),点一个 → 时间线只看它的对话。
    @ViewBuilder
    private func agentFilterBar(record: LingShuTaskExecutionRecord) -> some View {
        let agents = agentList(record)
        if agents.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    agentChip("全部", icon: "person.3.fill", count: record.messages.count, selected: selectedAgent == nil) { selectedAgent = nil }
                    ForEach(agents, id: \.name) { a in
                        agentChip(a.name, icon: "person.fill", count: a.count, selected: selectedAgent == a.name) {
                            selectedAgent = (selectedAgent == a.name) ? nil : a.name
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .background(Color.lingBar)
            .overlay(alignment: .bottom) { Divider().overlay(Color.lingFg.opacity(0.08)) }
        }
    }

    private func agentChip(_ name: String, icon: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 8.5, weight: .bold))
                Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("\(count)").font(.system(size: 9.5, weight: .bold, design: .monospaced)).opacity(0.7)
            }
            .foregroundStyle(selected ? Color.lingVoid : Color.lingFg.opacity(0.82))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? Color.lingHolo : Color.lingFg.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("只看「\(name)」的对话")
    }

    private func timelineColumn(record: LingShuTaskExecutionRecord) -> some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !lineageRecords.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.lingHolo)
                                    Text("续接历史流程")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(Color.lingFg.opacity(0.92))
                                    Text("\(lineageRecords.count) 段")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.lingFg.opacity(0.42))
                                }

                                ForEach(lineageRecords) { historicalRecord in
                                    TaskExecutionRecordHistoryBlock(record: historicalRecord)
                                }
                            }

                            Divider()
                                .overlay(Color.lingFg.opacity(0.12))
                                .padding(.vertical, 4)

                            HStack(spacing: 8) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.lingHolo)
                                Text("本轮执行")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(Color.lingFg.opacity(0.92))
                            }
                        }

                        // 计划 / 任务摘要 / 产出物 一律移到右侧侧栏(TaskDevToolsPanel);
                        // 左栏对**所有**任务(开发与交付统一)只留对话叙述(据用户反馈 2026-06-15)。

                        let shownMessages = selectedAgent == nil ? record.messages : record.messages.filter { $0.actor == selectedAgent }
                        ForEach(shownMessages) { message in
                            TaskExecutionMessageRow(message: message, state: state, recordID: record.id)
                        }
                        if shownMessages.isEmpty {
                            Text("「\(selectedAgent ?? "")」这个参与方在本任务里还没有消息。")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.lingFg.opacity(0.4))
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("task-record-bottom")
                    }
                    .padding(18)
                }
                .onAppear {
                    proxy.scrollTo("task-record-bottom", anchor: .bottom)
                }
                // 执行进行中：新阶段/工具消息一到就自动滚到底，实时跟住"一边执行一边汇报"。
                .onChange(of: record.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("task-record-bottom", anchor: .bottom)
                    }
                }
            }
    }
}

/// 任务详情右侧的产出文件面板：聚合本轮与续接历史的所有产物，
/// 本机存在的文件可预览、打开或在访达中显示。
struct TaskArtifactFilesPanel: View {
    let record: LingShuTaskExecutionRecord
    let lineageRecords: [LingShuTaskExecutionRecord]

    /// 两个独立模块:产出物(文件) / 代码改动(git)。代码改动 tab 仅在有代码改动时出现。
    private enum Tab { case artifacts, code }
    @State private var tab: Tab = .artifacts

    private var allArtifacts: [(artifact: LingShuTaskExecutionArtifact, fromHistory: Bool)] {
        let current = record.artifacts.map { (artifact: $0, fromHistory: false) }
        let historical = lineageRecords
            .flatMap(\.artifacts)
            .filter { artifact in !record.artifacts.contains(where: { $0.id == artifact.id }) }
            .map { (artifact: $0, fromHistory: true) }
        return (current + historical).sorted { $0.artifact.createdAt > $1.artifact.createdAt }
    }

    private var hasCode: Bool { record.codeChanges != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部 tab 栏:有代码改动才显示"代码改动"页;否则只有"产出物"(非代码需求连这页都不需要)。
            HStack(spacing: 4) {
                tabButton("产出物", systemImage: "folder.fill", count: allArtifacts.count, active: tab == .artifacts) { tab = .artifacts }
                if hasCode {
                    tabButton("代码改动", systemImage: "arrow.triangle.branch", count: record.codeChanges?.files.count ?? 0, active: tab == .code) { tab = .code }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.lingBar)
            .overlay(alignment: .bottom) { Divider().overlay(Color.lingFg.opacity(0.08)) }

            Group {
                if tab == .code, let code = record.codeChanges {
                    ScrollView { codeChangesBlock(code).padding(10) }
                } else if allArtifacts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color.lingFg.opacity(0.22))
                        Text("本任务还没有登记产出文件")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.lingFg.opacity(0.38))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            fileSection("新增", color: .lingHolo, entries: allArtifacts.filter { ($0.artifact.operation ?? .created) == .created })
                            fileSection("修改", color: .lingHoloAlt, entries: allArtifacts.filter { $0.artifact.operation == .modified })
                        }
                        .padding(10)
                    }
                }
            }
        }
        .background(Color.lingFg.opacity(0.03))   // 极淡面板底(适配两侧),原 black@0.28 在浅色=脏暗块
        .onChange(of: hasCode) { _, has in if !has, tab == .code { tab = .artifacts } }
    }

    @ViewBuilder
    private func tabButton(_ title: String, systemImage: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12, weight: .bold))
                Text("\(count)").font(.system(size: 10, weight: .bold, design: .monospaced)).opacity(0.6)
            }
            .foregroundStyle(active ? Color.lingHolo : Color.lingFg.opacity(0.5))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(active ? Color.lingHolo.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 代码改动块:当前分支 + 未提交改动文件(已提交的不在 porcelain 里 → 自然不统计)。
    @ViewBuilder
    private func codeChangesBlock(_ code: LingShuCodeChangeSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.lingHoloAlt)
                Text("代码改动")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.lingFg.opacity(0.6))
                Spacer()
                Text(code.branch)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHoloAlt)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text("\(code.repoName) · \(code.files.count) 个未提交改动(已提交的不计)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.4))
            ForEach(code.files) { f in
                HStack(spacing: 7) {
                    Text(f.label)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(f.label == "删除" ? .red.opacity(0.85) : (f.label == "新增" || f.label == "未跟踪" ? Color.lingHolo : Color.lingHoloAlt))
                        .frame(width: 34, alignment: .leading)
                    Text(f.path)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.82))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lingHoloAlt.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.lingHoloAlt.opacity(0.22), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private func fileSection(_ title: String, color: Color, entries: [(artifact: LingShuTaskExecutionArtifact, fromHistory: Bool)]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(color)
                    Text("\(entries.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color.lingFg.opacity(0.4))
                }
                ForEach(entries, id: \.artifact.id) { entry in
                    TaskArtifactFileCard(artifact: entry.artifact, fromHistory: entry.fromHistory)
                }
            }
        }
    }
}

/// 单个产物文件卡片：图标按扩展名区分，本机文件提供预览/打开/访达操作。
struct TaskArtifactFileCard: View {
    let artifact: LingShuTaskExecutionArtifact
    var fromHistory = false
    @State private var isPreviewing = false

    private var localFileURL: URL? {
        let path = artifact.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var fileName: String {
        let path = artifact.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return artifact.location }
        return (path as NSString).lastPathComponent
    }

    private var fileSizeText: String? {
        guard let url = localFileURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var fileIcon: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt": return "doc.text.fill"
        case "pdf": return "doc.richtext.fill"
        case "pptx", "key": return "rectangle.on.rectangle.angled.fill"
        case "html", "htm": return "globe"
        case "json", "csv", "yaml", "yml": return "tablecells.fill"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo.fill"
        case "mp4", "mov": return "film.fill"
        case "mp3", "wav", "m4a": return "waveform"
        case "swift", "py", "js", "ts", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: fileIcon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(localFileURL != nil ? Color.lingHolo : Color.lingFg.opacity(0.4))
                    .frame(width: 30, height: 30)
                    .background(Color.lingHolo.opacity(localFileURL != nil ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.title)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.9))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        let op = artifact.operation ?? .created
                        Text(op.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(op == .modified ? Color.lingHoloAlt : Color.lingHolo)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background((op == .modified ? Color.lingHoloAlt : Color.lingHolo).opacity(0.16), in: Capsule())
                        if fromHistory {
                            Text("历史")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.lingFg.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.lingFg.opacity(0.08), in: Capsule())
                        }
                        Text(artifact.createdAt.taskRecordDisplayTime)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.lingFg.opacity(0.36))
                        if let sizeText = fileSizeText {
                            Text(sizeText)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.lingFg.opacity(0.42))
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            Text(fileName)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.lingFg.opacity(localFileURL != nil ? 0.6 : 0.34))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(artifact.location)

            if let url = localFileURL {
                HStack(spacing: 6) {
                    artifactActionButton("预览", icon: "eye") { isPreviewing = true }
                    artifactActionButton("打开", icon: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(url)
                    }
                    artifactActionButton("打开目录", icon: "folder") {
                        // 在访达里打开该文件所在目录并选中它(reveal in Finder)。
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } else if artifact.location.hasPrefix("/") {
                Text("文件已不存在")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.7))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.lingHolo.opacity(localFileURL != nil ? 0.18 : 0.07))
        }
        .sheet(isPresented: $isPreviewing) {
            if let url = localFileURL {
                LingShuArtifactPreviewSheet(title: artifact.title, fileURL: url) { isPreviewing = false }
            }
        }
    }

    private func artifactActionButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.lingHolo.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.lingHolo.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct TaskExecutionRecordHistoryBlock: View {
    let record: LingShuTaskExecutionRecord

    private var visibleMessages: [LingShuTaskExecutionMessage] {
        Array(record.messages.suffix(18))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Color.lingFg.opacity(0.9))
                    .lineLimit(1)
                Text(record.status.rawValue)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(record.status.color)
                Spacer()
                Text(record.updatedAt.taskRecordDisplayTime)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.34))
            }

            Text(record.summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleMessages) { message in
                    TaskExecutionMessageRow(message: message)
                }
                if record.messages.count > visibleMessages.count {
                    Text("已折叠更早的 \(record.messages.count - visibleMessages.count) 条历史进度。")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.38))
                        .padding(.leading, 38)
                }
            }
        }
        .padding(12)
        .background(Color.lingFg.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.16))
        }
    }
}

struct TaskExecutionArtifactRow: View {
    let artifact: LingShuTaskExecutionArtifact
    @State private var isPreviewing = false

    /// 仅本机存在的文件可预览（云端链接/非文件位置不可预览）。
    private var localFileURL: URL? {
        let path = artifact.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.lingHolo)
                .frame(width: 28, height: 28)
                .background(Color.lingHolo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(artifact.title)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color.lingFg.opacity(0.9))
                        .lineLimit(1)
                    Text(artifact.producer)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.42))
                    Text(artifact.createdAt.taskRecordDisplayTime)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.34))
                    Spacer()
                    if localFileURL != nil {
                        Button {
                            isPreviewing = true
                        } label: {
                            Label("预览", systemImage: "eye")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color.lingHolo)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(artifact.location)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.lingFg.opacity(0.62))
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .sheet(isPresented: $isPreviewing) {
            if let url = localFileURL {
                LingShuArtifactPreviewSheet(title: artifact.title, fileURL: url) { isPreviewing = false }
            }
        }
    }
}

struct TaskExecutionMessageRow: View {
    let message: LingShuTaskExecutionMessage
    /// 非空 = 可交互(本轮记录,diff 卡可撤销);nil = 历史/只读。
    var state: LingShuState? = nil
    var recordID: String? = nil

    var body: some View {
        if let detail = message.detail {
            // 结构化载荷 → codex 式卡片(命令/结果/diff),左对齐 + actor 徽标。
            HStack(alignment: .top, spacing: 10) {
                actorBadge
                detailCard(detail)
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 40)
            }
        } else {
            textRow
        }
    }

    @ViewBuilder
    private func detailCard(_ detail: LingShuTaskExecutionDetail) -> some View {
        switch detail {
        case let .toolCall(tool, summary, arguments):
            TaskToolCallCard(tool: tool, summary: summary, arguments: arguments)
        case let .toolResult(tool, success, output):
            TaskToolResultCard(tool: tool, success: success, output: output)
        case let .fileEdit(path, operation, added, removed, diff):
            TaskFileDiffCard(
                path: path, operation: operation, added: added, removed: removed, diff: diff,
                undone: message.undone ?? false,
                onUndo: (state != nil && recordID != nil) ? { [id = message.id, recordID] in
                    if let recordID { state?.undoFileEdit(messageID: id, recordID: recordID) }
                } : nil
            )
        }
    }

    private var textRow: some View {
        let isUser = message.kind == .user

        return HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer(minLength: 90)
            } else {
                actorBadge
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if isUser { Spacer(minLength: 0) }
                    Text(message.actor)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(message.kind.color.opacity(0.94))
                    Text(message.role)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.42))
                    Text(message.timestamp.taskRecordDisplayTime)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.34))
                }

                Group {
                    if isUser {
                        // 用户输入:纯文本气泡。
                        Text(message.text)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.lingFg.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // 灵枢分析/答复:markdown 渲染(代码块/列表/表格),对齐 codex 阅读体验。
                        LingShuMessageContentView(text: message.text, textColor: Color.lingFg.opacity(0.88))
                    }
                }
                .padding(12)
                .background(isUser ? Color.lingHolo.opacity(0.20) : Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isUser ? Color.lingHolo.opacity(0.28) : message.kind.color.opacity(0.18))
                }
            }
            .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 60)
            }
        }
    }

    private var actorBadge: some View {
        Image(systemName: message.kind.icon)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(message.kind.color)
            .frame(width: 28, height: 28)
            .background(message.kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
