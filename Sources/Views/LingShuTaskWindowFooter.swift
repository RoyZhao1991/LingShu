import SwiftUI
import UniformTypeIdentifiers

/// 任务窗口底部条(对齐 codex 聊天窗口):模型选择 + 👍👎反馈 + 窗口内追问输入。
/// 与消息卡片渲染(LingShuTaskWindowCards)分文件——交互/输入 ↔ 展示是两个关注点。
struct TaskWindowFooter: View {
    @ObservedObject var state: LingShuState
    let recordID: String
    @State private var draft = ""

    private var feedback: Bool? { state.taskRecordFeedback[recordID] }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                modelPicker
                Spacer(minLength: 0)
                feedbackButton(up: true)
                feedbackButton(up: false)
            }
            // 待发送附件托盘(与主输入框同一套 ingest 管线 + 同一缓冲)。
            if !state.pendingAttachments.isEmpty {
                LingShuAttachmentTray(state: state, inputStore: state.inputStore)
            }
            followupInput
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.lingBar)   // 浅=白 chrome / 深=半透明暗条(原 black@0.6 在浅色=突兀暗条)
        .overlay(alignment: .top) { Divider().overlay(Color.lingFg.opacity(0.08)) }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(state.taskWindowModelProviders, id: \.self) { provider in
                Button(provider) { state.applyModelProvider(provider) }
            }
            if !state.availableModelNames.isEmpty {
                Divider()
                ForEach(state.availableModelNames, id: \.self) { model in
                    Button(model) { state.modelName = model }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 10, weight: .bold))
                Text(state.modelName).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.lingFg.opacity(0.66))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.lingFg.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var running: Bool { state.canStopTaskWindowRecord(recordID) }

    private var followupInput: some View {
        VStack(spacing: 6) {
            // 执行中:提示可随时纠偏 + 停止。
            if running {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.orange.opacity(0.9))
                    Text(state.loc(
                        "灵枢正在执行——看到跑偏可直接输入纠正，立即调整方向",
                        "LingShu is running — send a correction at any time to adjust course"
                    ))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange.opacity(0.82))
                    Spacer(minLength: 0)
                    Button { state.stopTaskWindowRecord(recordID) } label: {
                        Label(state.loc("停止", "Stop"), systemImage: "stop.fill")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.red.opacity(0.92))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                // 附件上传(子任务窗口也能传文件了):📎 → 选文件 → 走同一 ingest 管线。
                Button(action: state.presentAttachmentPicker) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(state.pendingAttachments.isEmpty ? Color.lingFg.opacity(0.7) : Color.lingHolo)
                        .frame(width: 34, height: 34)
                        .background(Color.lingFg.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(state.loc("为这条任务上传附件", "Upload an Attachment to This Task"))

                TextField(
                    running
                    ? state.loc("回复这条线程…（执行中也会立即采纳）", "Reply to this thread… (applied while running)")
                    : state.loc("回复这条线程…（发消息就续跑）", "Reply to this thread… (send to continue)"),
                    text: $draft,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.lingFg)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.lingFg.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke((running ? Color.orange : Color.lingHolo).opacity(0.22))
                    }
                    .onSubmit(send)
                    // **粘贴截图进附件栏**(对齐 codex/claude):Cmd+V 命中图片 → 走稳健取图 → 落成附件(与主输入框同一 ingest 管线)。
                    .onPasteCommand(of: [UTType.image, UTType.png, UTType.tiff]) { _ in
                        if let png = LingShuInputTextView.pngFromPasteboard(.general) { state.ingestPastedImage(png) }
                    }
                    // 拖入文件落成路径文本时,整框=纯路径就转成附件(与主输入框同行为),别直接当路径文本发。
                    .onChange(of: draft) { _, newValue in
                        if state.convertDroppedFilePaths(in: newValue) { draft = "" }
                    }

                Button(action: send) {
                    Image(systemName: running ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(canSend ? (running ? Color.orange : Color.lingHolo) : Color.lingFg.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(running
                      ? state.loc("把纠正发给正在执行的灵枢（立即纠偏）", "Send a Correction to the Running Task")
                      : state.loc("继续这条任务", "Continue This Task"))
            }
        }
    }

    /// 只要有文字或附件即可发。子线程=独立隔离线程,发消息就续跑(对齐 codex)。
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.pendingAttachments.isEmpty
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        // **统一入口(对齐 codex 子线程):发消息→续这条隔离线程**——在飞就 steer 注入、没在飞就 re-engage 续跑,
        // 始终产出执行+回复。不再按不可靠的「执行中」标志分「纠正/追问」两套(根治「子线程收到没回复」)。
        state.continueTaskThread(text, recordID: recordID)
    }

    private func feedbackButton(up: Bool) -> some View {
        let active = feedback == up
        return Button {
            state.setTaskFeedback(active ? nil : up, recordID: recordID)
        } label: {
            Image(systemName: up ? (active ? "hand.thumbsup.fill" : "hand.thumbsup") : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? (up ? Color.green : Color.orange) : Color.lingFg.opacity(0.4))
                .frame(width: 28, height: 26)
                .background(Color.lingFg.opacity(active ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
