import SwiftUI
import AppKit

struct TaskExecutionRecordSheet: View {
    @ObservedObject var state: LingShuState
    @Environment(\.dismiss) private var dismiss

    // 从 state 实时取记录:执行流/diff/追问续跑都会即时反映到窗口。
    private var record: LingShuTaskExecutionRecord? { state.selectedTaskRecord }
    private var lineageRecords: [LingShuTaskExecutionRecord] { state.selectedTaskRecordLineage }

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
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(record.status.rawValue)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(record.status.color)
                        Text("\(record.participants.count) 个参与方")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.52))
                        Text(record.updatedAt.taskRecordDisplayTime)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                        // 开发任务:头部补仓库 + 分支 chip(对齐 codex 开发窗口)。
                        if let code = record.codeChanges {
                            headerChip(code.repoName, icon: "folder.fill")
                            headerChip(code.branch, icon: "arrow.triangle.branch")
                        }
                    }
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .background(Color.black.opacity(0.72))

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    timelineColumn(record: record)
                    Divider().overlay(Color.white.opacity(0.08))
                    // 窗口内追问 + 模型选择 + 反馈(codex 式聊天窗口)。
                    TaskWindowFooter(state: state, recordID: record.id)
                }
                Divider()
                    .overlay(Color.white.opacity(0.1))
                // 统一侧栏:所有任务都用 TaskDevToolsPanel(目标/任务摘要/进度/产出物);
                // 「Git 工具」段仅开发任务显示,交付任务(PPT 等)自动隐藏。
                TaskDevToolsPanel(state: state, record: record, lineageRecords: lineageRecords)
                    .frame(width: 300)
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
                                        .foregroundStyle(.white.opacity(0.92))
                                    Text("\(lineageRecords.count) 段")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.42))
                                }

                                ForEach(lineageRecords) { historicalRecord in
                                    TaskExecutionRecordHistoryBlock(record: historicalRecord)
                                }
                            }

                            Divider()
                                .overlay(Color.white.opacity(0.12))
                                .padding(.vertical, 4)

                            HStack(spacing: 8) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.lingHolo)
                                Text("本轮执行")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                        }

                        // 计划 / 任务摘要 / 产出物 一律移到右侧侧栏(TaskDevToolsPanel);
                        // 左栏对**所有**任务(开发与交付统一)只留对话叙述(据用户反馈 2026-06-15)。

                        ForEach(record.messages) { message in
                            TaskExecutionMessageRow(message: message, state: state, recordID: record.id)
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
            .background(Color.black.opacity(0.5))

            Group {
                if tab == .code, let code = record.codeChanges {
                    ScrollView { codeChangesBlock(code).padding(10) }
                } else if allArtifacts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.22))
                        Text("本任务还没有登记产出文件")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
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
        .background(Color.black.opacity(0.28))
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
            .foregroundStyle(active ? Color.lingHolo : .white.opacity(0.5))
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
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(code.branch)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.lingHoloAlt)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text("\(code.repoName) · \(code.files.count) 个未提交改动(已提交的不计)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            ForEach(code.files) { f in
                HStack(spacing: 7) {
                    Text(f.label)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(f.label == "删除" ? .red.opacity(0.85) : (f.label == "新增" || f.label == "未跟踪" ? Color.lingHolo : Color.lingHoloAlt))
                        .frame(width: 34, alignment: .leading)
                    Text(f.path)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
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
                    Text("\(entries.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
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
                    .foregroundStyle(localFileURL != nil ? Color.lingHolo : Color.white.opacity(0.4))
                    .frame(width: 30, height: 30)
                    .background(Color.lingHolo.opacity(localFileURL != nil ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.title)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
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
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        Text(artifact.createdAt.taskRecordDisplayTime)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.36))
                        if let sizeText = fileSizeText {
                            Text(sizeText)
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            Text(fileName)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(localFileURL != nil ? 0.6 : 0.34))
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
                    artifactActionButton("访达", icon: "folder") {
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
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.lingHolo.opacity(localFileURL != nil ? 0.18 : 0.07))
        }
        .sheet(isPresented: $isPreviewing) {
            if let url = localFileURL {
                LingShuArtifactPreviewSheet(title: artifact.title, fileURL: url)
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
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(record.status.rawValue)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(record.status.color)
                Spacer()
                Text(record.updatedAt.taskRecordDisplayTime)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
            }

            Text(record.summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleMessages) { message in
                    TaskExecutionMessageRow(message: message)
                }
                if record.messages.count > visibleMessages.count {
                    Text("已折叠更早的 \(record.messages.count - visibleMessages.count) 条历史进度。")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.leading, 38)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(artifact.producer)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                    Text(artifact.createdAt.taskRecordDisplayTime)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
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
                    .foregroundStyle(.white.opacity(0.62))
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .sheet(isPresented: $isPreviewing) {
            if let url = localFileURL {
                LingShuArtifactPreviewSheet(title: artifact.title, fileURL: url)
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
                        .foregroundStyle(.white.opacity(0.42))
                    Text(message.timestamp.taskRecordDisplayTime)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
                }

                Group {
                    if isUser {
                        // 用户输入:纯文本气泡。
                        Text(message.text)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // 灵枢分析/答复:markdown 渲染(代码块/列表/表格),对齐 codex 阅读体验。
                        LingShuMessageContentView(text: message.text, textColor: .white.opacity(0.88))
                    }
                }
                .padding(12)
                .background(isUser ? Color.lingHolo.opacity(0.20) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
