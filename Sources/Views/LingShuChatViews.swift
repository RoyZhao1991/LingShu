import AppKit
import SwiftUI

/// 任务执行时主线程对话里的紧凑状态行：转圈 + 当前步骤名 + 实时耗时 + 最近诊断。
/// 主线程只报关键事实（当前计划、最近工具/文件动作、心跳/trace）；点一下进**任务子线程窗口**
/// 看一边执行一边汇报的多段过程（规划/产出/工具/评审/纠正…全程，与主线程互不干扰）。
struct LingShuTaskProgressIndicator: View {
    let stage: String
    let startedAt: Date
    var diagnosticProvider: ((Date) -> LingShuTaskProgressDiagnostic?)?
    var onOpen: (() -> Void)?

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) {
                    progressContent
                }
                .buttonStyle(.plain)
                .help(LingShuLanguagePreferenceStore.localized(
                    "打开任务子线程窗口，实时查看多段执行过程",
                    "Open the task thread to view live execution details"
                ))
            } else {
                progressContent
            }
        }
    }

    private var progressContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            let diagnostic = diagnosticProvider?(context.date)

            VStack(alignment: .leading, spacing: diagnostic == nil ? 0 : 6) {
                HStack(spacing: 9) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Color.lingHolo)
                        .frame(width: 16, height: 16)
                    Text(stage)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.lingFg.opacity(0.85))
                    Text("\(elapsed)s")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.4))
                    Spacer(minLength: 8)
                    if onOpen != nil {
                        HStack(spacing: 3) {
                            Image(systemName: "rectangle.split.2x1")
                            Text(LingShuLanguagePreferenceStore.localized("查看执行过程", "View Progress"))
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.lingHolo.opacity(0.85))
                    }
                }

                if let diagnostic {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: diagnostic.isStale || diagnostic.isTerminalButLoading ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(diagnostic.isStale || diagnostic.isTerminalButLoading ? Color.orange.opacity(0.86) : Color.lingHolo.opacity(0.74))
                            Text(diagnostic.phase)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color.lingHolo.opacity(0.82))
                            Text(diagnostic.headline)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.lingFg.opacity(0.68))
                                .lineLimit(1)
                        }

                        if !diagnostic.detail.isEmpty {
                            Text(diagnostic.detail)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.lingFg.opacity(0.52))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        diagnosticRunBar(diagnostic)

                        if let trace = diagnostic.lastTrace {
                            Text(trace)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.lingFg.opacity(0.36))
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 25)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func diagnosticRunBar(_ diagnostic: LingShuTaskProgressDiagnostic) -> some View {
        HStack(spacing: 5) {
            diagnosticChip("record", diagnostic.recordIDShort, monospaced: true)
            diagnosticChip("trace", diagnostic.lastTraceTime, monospaced: true)
            diagnosticChip("step", diagnostic.currentStep)
                .layoutPriority(1)
            diagnosticChip("wait", diagnostic.waitState, warning: diagnostic.isStale || diagnostic.isTerminalButLoading)
            diagnosticChip("hb", diagnostic.heartbeatText, warning: diagnostic.isStale)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.lingFg.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.lingHolo.opacity(0.10), lineWidth: 1)
        )
    }

    private func diagnosticChip(
        _ label: String,
        _ value: String,
        warning: Bool = false,
        monospaced: Bool = false
    ) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .foregroundStyle(Color.lingFg.opacity(0.34))
            Text(value)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(warning ? Color.orange.opacity(0.88) : Color.lingFg.opacity(0.58))
        }
        .font(.system(size: 9.6, weight: .semibold, design: monospaced ? .monospaced : .default))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            Capsule(style: .continuous)
                .fill((warning ? Color.orange : Color.lingHolo).opacity(0.075))
        )
    }
}

/// 点开附件重新预览时的目标(`.sheet(item:)` 要 Identifiable)。
struct AttachmentPreviewItem: Identifiable { let id = UUID(); let url: URL }

struct ChatBubbleView: View {
    let message: ChatMessage
    @ObservedObject var state: LingShuState
    /// 霓虹侧条的"呼吸"相位——轻微动效,看着更科幻(只动一根 2px 条 + 描边,开销极小)。
    @State private var glow = false
    /// 气泡内"追加信息"输入(任务等用户输入时)。
    @State private var taskReplyText = ""
    /// 点击已发送附件 → 重新预览的目标。
    @State private var previewItem: AttachmentPreviewItem?

    private var accent: Color { message.isUser ? .lingHolo : .lingHoloAlt }
    /// 所有模型通道共用同一展示清洗:解开结构化 reply,并兼容历史截断协议消息。
    private var renderedMessageText: String {
        message.isUser ? message.text : LingShuVisibleModelText.clean(message.text)
    }
    private var hasCopyableText: Bool {
        !renderedMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 气泡内回复直达该任务的隔离会话(不经主输入/分诊)。
    private func sendTaskReply(_ recordID: String) {
        let t = taskReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        taskReplyText = ""
        state.answerDispatchedTask(recordID: recordID, answer: t)
    }

    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if message.isUser { Spacer(minLength: 0) }
                    Text(message.isUser ? state.loc("你", "You") : state.appName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(message.isUser ? Color.lingFg.opacity(0.72) : Color.lingHolo.opacity(0.84))
                    Text(message.createdAt.chatBubbleDisplayTime)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.lingFg.opacity(0.34))
                    if !message.isUser { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)

                if message.isLoading && !message.isUser {
                    // 已有流式正文(message.text 非空)→ 逐字显示;还没正文(工具执行中/未开始)→ 紧凑进度行。
                    if message.taskRecordID != nil && message.text.isEmpty {
                        // 任务执行：主线程只显示「当前步骤 + 耗时」的紧凑状态（语音友好、不刷屏）；
                        // 点一下进任务子线程窗口看实时的多段执行过程——对齐 codex/claude 的状态行做法。
                        // per-task 活动:显示**这条消息自己任务**的进度,不读全局 missionTitle(根治多任务并行时串台)。
                        HStack(spacing: 8) {
                            LingShuTaskProgressIndicator(
                                stage: state.activityLabel(for: message.taskRecordID),
                                startedAt: message.createdAt,
                                diagnosticProvider: { now in
                                    state.activityDiagnostic(for: message.taskRecordID, now: now)
                                },
                                onOpen: nil
                            )
                            // 问答线可删:**等待中(未执行)**的问答显示删除按钮(执行中的那条不可删)。
                            if state.canDeletePendingChatTurn(message.id) {
                                Button { state.deletePendingChatTurn(bubbleID: message.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color.lingFg.opacity(0.35))
                                }
                                .buttonStyle(.plain)
                                .help(state.loc("删除这条等待中的问答（执行中的不可删）", "Remove this queued turn"))
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 9) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(Color.lingHolo)
                                    .frame(width: 16, height: 16, alignment: .leading)

                                // 直答通道：流式片段一到就分块显示；还没有内容时只显示安静的“思考中…”。
                                if message.text.isEmpty {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        let elapsed = max(0, Int(context.date.timeIntervalSince(message.createdAt)))
                                        Text(state.loc(
                                            "思考中 \(Self.formatLoadingElapsed(elapsed))",
                                            "Thinking \(Self.formatLoadingElapsed(elapsed))"
                                        ))
                                            .font(.system(size: 14.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Color.lingFg.opacity(0.5))
                                    }
                                } else {
                                    LingShuMessageContentView(text: renderedMessageText) { url in
                                        previewItem = .init(url: url)
                                    }
                                }
                            }

                            // 模型的实时推理预览：滚动展示思考流的尾部，定稿即消失。
                            if let thinking = message.thinkingPreview, !thinking.isEmpty {
                                Text(thinking)
                                    .font(.system(size: 11.5, weight: .regular))
                                    .foregroundStyle(Color.lingFg.opacity(0.38))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 25)
                                    .transition(.opacity)
                                    .animation(.easeInOut(duration: 0.2), value: thinking)
                            }
                        }
                    }
                } else if message.isUser {
                    Text(message.text)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.lingFg.opacity(0.94))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    LingShuOpenablePathChips(text: message.text) { url in
                        previewItem = .init(url: url)
                    }
                    if let names = message.attachmentNames, !names.isEmpty {
                        // 已发送的附件:在消息气泡里展示(留痕);**点击可重新预览**(发送时已落到稳定目录,见 persistedSentAttachmentPath)。
                        FlowChips(names: names, paths: message.attachmentPaths) { url in previewItem = .init(url: url) }
                    }
                } else {
                    // 灵枢回复：结构化分块（代码块单独成卡片，正文走 Markdown）。
                    LingShuMessageContentView(text: renderedMessageText) { url in
                        previewItem = .init(url: url)
                    }
                        .textSelection(.enabled)
                }

                if !message.isUser, !message.isLoading, let choices = message.choices {
                    LingShuChoiceCard(
                        prompt: choices,
                        resolvedChoice: message.resolvedChoice
                    ) { option in
                        state.selectRouteChoice(option, for: message.id)
                    }
                }

                // 多项确认表单(每事项一行各带选择菜单 + 末行"其他(自行输入)")。
                if !message.isUser, !message.isLoading, let form = message.form {
                    LingShuFormCard(form: form, resolved: message.formAnswers) { answers in
                        state.submitFormAnswers(answers, for: message.id)
                    }
                }

                if !message.isUser, !message.isLoading, let interaction = message.humanInteraction {
                    LingShuHumanInteractionCard(state: state, request: interaction) { answer, displayAnswer in
                        if let recordID = message.awaitingInputForRecordID {
                            state.answerDispatchedTask(
                                recordID: recordID,
                                answer: answer,
                                displayAnswer: displayAnswer
                            )
                        } else {
                            state.resolveMainHumanInteraction(
                                messageID: message.id,
                                answer: answer,
                                displayAnswer: displayAnswer
                            )
                        }
                    }
                }

                // **气泡内追加信息**:这条任务在等用户输入 → 从气泡直接回复(选项上方/无选项时单独),
                // 答复**直达该任务隔离会话**(不经主输入/分诊),不怕被后续聊天淹没。
                if !message.isUser, let rid = message.awaitingInputForRecordID {
                    HStack(spacing: 6) {
                        TextField(state.loc("回复这条任务(如 A / B,或补充信息)…", "Reply to this task…"),
                                  text: $taskReplyText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onSubmit { sendTaskReply(rid) }
                        Button { sendTaskReply(rid) } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                                .foregroundStyle(Color.lingHolo)
                        }
                        .buttonStyle(.plain)
                        .disabled(taskReplyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)
                }

                if !message.isUser,
                   let taskRecordID = message.taskRecordID,
                   state.canOpenTaskRecord(taskRecordID) {
                    Button {
                        state.openTaskRecord(taskRecordID)
                    } label: {
                        Label(state.loc("查看任务执行记录", "View task record"), systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.lingHolo.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.lingHolo.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.lingHolo.opacity(0.18))
                            }
                    }
                    .buttonStyle(.plain)
                    .help(state.loc("打开本轮任务的 Agent 协作执行记录", "Open the agent collaboration record"))
                }

                if hasCopyableText {
                    LingShuBubbleCopyBar(markdown: renderedMessageText)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: message.isUser ? 420 : 760, alignment: message.isUser ? .trailing : .leading)
            .background(
                LinearGradient(
                    colors: message.isUser
                        ? [Color.lingHolo.opacity(0.16), Color.lingHolo.opacity(0.05)]
                        : [Color.lingFg.opacity(0.06), Color.lingFg.opacity(0.02)],
                    startPoint: message.isUser ? .topTrailing : .topLeading,
                    endPoint: message.isUser ? .bottomLeading : .bottomTrailing
                )
            )
            .overlay(alignment: message.isUser ? .trailing : .leading) {
                // 霓虹侧条:缓慢呼吸的辉光(opacity + shadow 在两值间往返),像"通电"的感觉。
                Rectangle()
                    .fill(accent.opacity(glow ? 0.95 : 0.55))
                    .frame(width: 2)
                    .shadow(color: accent.opacity(glow ? 0.85 : 0.3), radius: glow ? 6 : 2)
            }
            .overlay {
                // 描边也随呼吸极轻微地亮一下(克制,避免闪烁)。
                Rectangle()
                    .stroke((message.isUser ? Color.lingHolo : Color.white).opacity((message.isUser ? 0.22 : 0.08) + (glow ? 0.06 : 0)), lineWidth: 0.8)
            }

            if !message.isUser {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { glow = true }
        }
        .sheet(item: $previewItem) { item in
            LingShuArtifactPreviewSheet(title: item.url.lastPathComponent, fileURL: item.url) { previewItem = nil }
        }
    }

    private static func formatLoadingElapsed(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        return String(format: "%02d:%02d", minutes, rest)
    }
}

private struct LingShuBubbleCopyBar: View {
    let markdown: String
    @State private var copiedMode: CopyMode?

    private enum CopyMode {
        case plain
        case markdown

        var tipText: String {
            switch self {
            case .plain:
                return LingShuLanguagePreferenceStore.localized("已复制文本", "Text Copied")
            case .markdown:
                return LingShuLanguagePreferenceStore.localized("已复制 Markdown", "Markdown Copied")
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                copyPlain()
            } label: {
                Image(systemName: copiedMode == .plain ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(copiedMode == .plain ? Color.lingHolo : Color.lingFg.opacity(0.42))
            .help(LingShuLanguagePreferenceStore.localized("复制纯文本", "Copy Plain Text"))

            Button {
                copyMarkdown()
            } label: {
                Image(systemName: copiedMode == .markdown ? "checkmark" : "curlybraces")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(copiedMode == .markdown ? Color.lingHolo : Color.lingFg.opacity(0.42))
            .help(LingShuLanguagePreferenceStore.localized("复制 Markdown", "Copy Markdown"))

            if let copiedMode {
                Text(copiedMode.tipText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lingHolo)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.lingHolo.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.lingHolo.opacity(0.26), lineWidth: 0.8)
                    )
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .opacity(0.86)
        .animation(.easeOut(duration: 0.16), value: copiedMode)
    }

    private func copyPlain() {
        LingShuBubbleClipboard.copyPlainText(fromMarkdown: markdown)
        flash(.plain)
    }

    private func copyMarkdown() {
        LingShuBubbleClipboard.copyMarkdown(markdown)
        flash(.markdown)
    }

    private func flash(_ mode: CopyMode) {
        withAnimation(.easeOut(duration: 0.16)) {
            copiedMode = mode
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedMode == mode {
                withAnimation(.easeOut(duration: 0.16)) {
                    copiedMode = nil
                }
            }
        }
    }
}

private enum LingShuBubbleClipboard {
    static func copyPlainText(fromMarkdown markdown: String) {
        copy(string: plainText(fromMarkdown: markdown), includeMarkdownType: false)
    }

    static func copyMarkdown(_ markdown: String) {
        copy(string: markdown, includeMarkdownType: true)
    }

    private static func copy(string: String, includeMarkdownType: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        if includeMarkdownType {
            pasteboard.setString(string, forType: NSPasteboard.PasteboardType("public.markdown"))
            pasteboard.setString(string, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
        }
    }

    static func plainText(fromMarkdown markdown: String) -> String {
        var output: [String] = []
        var inCodeBlock = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if !inCodeBlock {
                line = line.replacingOccurrences(of: "^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: "^\\s{0,3}>\\s?", with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: "^\\s*[-*+]\\s+", with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: "^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
                line = line.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
                line = line.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
                line = line.replacingOccurrences(of: "(`+)(.*?)\\1", with: "$2", options: .regularExpression)
                line = line.replacingOccurrences(of: "(\\*\\*|__)(.*?)\\1", with: "$2", options: .regularExpression)
                line = line.replacingOccurrences(of: "(\\*|_)(.*?)\\1", with: "$2", options: .regularExpression)
                line = line.replacingOccurrences(of: "~~(.*?)~~", with: "$1", options: .regularExpression)
            }
            output.append(line)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 已发送附件的小芯片(在用户消息气泡里展示):文件图标 + 文件名。竖排,最多展示 6 个 + 计数。
struct FlowChips: View {
    let names: [String]
    /// 与 names 平行的本地路径(可点重新预览);nil/空串=该条不可预览(旧记录/无落地文件)。
    var paths: [String]? = nil
    var onPreview: ((URL) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(names.enumerated().prefix(6)), id: \.offset) { idx, name in
                let path = (paths.flatMap { idx < $0.count ? $0[idx] : nil }) ?? ""
                let previewable = !path.isEmpty && onPreview != nil && FileManager.default.fileExists(atPath: path)
                if previewable {
                    Button { onPreview?(URL(fileURLWithPath: path)) } label: { chip(name, previewable: true) }
                        .buttonStyle(.plain)
                        .help(LingShuLanguagePreferenceStore.localized("点击重新预览", "Preview Again"))
                } else {
                    chip(name, previewable: false)
                }
            }
            if names.count > 6 {
                Text(LingShuLanguagePreferenceStore.localized(
                    "共 \(names.count) 个文件",
                    "\(names.count) files total"
                ))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.lingFg.opacity(0.5))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func chip(_ name: String, previewable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: name))
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.lingHolo)
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.lingFg.opacity(0.82))
                .lineLimit(1).truncationMode(.middle)
            if previewable {
                Image(systemName: "eye").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.lingFg.opacity(0.4))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.lingFg.opacity(previewable ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 7))
    }
    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "xlsx", "xls", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle.angled"
        case "doc", "docx": return "doc.text"
        default: return "doc"
        }
    }
}
