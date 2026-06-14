import SwiftUI
import AppKit

struct TaskExecutionRecordSheet: View {
    let record: LingShuTaskExecutionRecord
    let lineageRecords: [LingShuTaskExecutionRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                timelineColumn
                Divider()
                    .overlay(Color.white.opacity(0.1))
                TaskArtifactFilesPanel(record: record, lineageRecords: lineageRecords)
                    .frame(width: 272)
            }
        }
        .frame(minWidth: 1020, minHeight: 620)
        .background(Color.lingVoid)
    }

    private var timelineColumn: some View {
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

                        VStack(alignment: .leading, spacing: 6) {
                            Text("任务摘要")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.lingHolo.opacity(0.88))
                            Text(record.summary)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.64))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        if !record.artifacts.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "shippingbox.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.lingHolo)
                                    Text("产出物")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.92))
                                    Text("\(record.artifacts.count) 项")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.42))
                                }

                                ForEach(record.artifacts) { artifact in
                                    TaskExecutionArtifactRow(artifact: artifact)
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.lingHolo.opacity(0.15))
                            }
                        }

                        ForEach(record.messages) { message in
                            TaskExecutionMessageRow(message: message)
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

    private var allArtifacts: [(artifact: LingShuTaskExecutionArtifact, fromHistory: Bool)] {
        let current = record.artifacts.map { (artifact: $0, fromHistory: false) }
        let historical = lineageRecords
            .flatMap(\.artifacts)
            .filter { artifact in !record.artifacts.contains(where: { $0.id == artifact.id }) }
            .map { (artifact: $0, fromHistory: true) }
        return (current + historical).sorted { $0.artifact.createdAt > $1.artifact.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.lingHolo)
                Text("任务产出文件")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("\(allArtifacts.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.5))

            if allArtifacts.isEmpty {
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
                        // 按文件操作类型分组(对齐 codex):新增 / 修改。
                        fileSection("新增", color: .lingHolo, entries: allArtifacts.filter { ($0.artifact.operation ?? .created) == .created })
                        fileSection("修改", color: .lingHoloAlt, entries: allArtifacts.filter { $0.artifact.operation == .modified })
                    }
                    .padding(10)
                }
            }
        }
        .background(Color.black.opacity(0.28))
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

    var body: some View {
        let isUser = message.kind == .user

        HStack(alignment: .top, spacing: 10) {
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

                Text(message.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .background(isUser ? Color.lingHolo.opacity(0.20) : Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isUser ? Color.lingHolo.opacity(0.28) : message.kind.color.opacity(0.18))
                    }
            }
            .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 90)
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
